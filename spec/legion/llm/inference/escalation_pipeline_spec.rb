# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm'
require 'legion/llm/quality/checker'
require 'legion/llm/router/escalation/chain'

RSpec.describe 'Pipeline escalation via step_provider_call' do
  let(:good_content) { 'This is a sufficiently long and varied response that passes all quality checks easily' }
  let(:short_content) { '' }

  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :bedrock, model: 'claude-sonnet-4-6' }
    )
  end

  # Register a second provider (anthropic) so the escalation chain has a real fallback
  def register_fallback_provider(content: nil)
    fallback_result = native_dispatch_result(content: content || good_content)
    Legion::LLM::Call::Registry.register(:anthropic, Module.new do
      define_singleton_method(:chat) { |**| fallback_result }
      define_singleton_method(:offerings) { [{ model: 'claude-sonnet-4-6' }] }
    end, metadata: { default_model: 'claude-sonnet-4-6' })
    # P5: write Inventory lane for anthropic fallback using the SAME model as bedrock
    # so request_lane (models filter) can find it for cross-provider failover.
    write_test_lane(provider: :anthropic, model: 'claude-sonnet-4-6', tier: :frontier)
  end

  before do
    Legion::LLM::Router.reset!
    Legion::Settings.set_prop(:llm, {
                                default_model:    'claude-sonnet-4-6',
                                default_provider: :bedrock,
                                providers:        { bedrock: { enabled: true, default_model: 'claude-sonnet-4-6' } },
                                discovery:        { enabled: false },
                                routing:          {
                                  enabled:        false,
                                  default_intent: {},
                                  escalation:     {
                                    enabled:           true,
                                    pipeline_enabled:  true,
                                    max_attempts:      3,
                                    quality_threshold: 50
                                  },
                                  rules:          []
                                }
                              })
    # Register bedrock in the registry so dispatching works
    Legion::LLM::Call::Registry.register(:bedrock, Module.new do
      define_singleton_method(:offerings) { [{ model: 'claude-sonnet-4-6' }] }
    end, metadata: { default_model: 'claude-sonnet-4-6' })
    # P5: write Inventory lane for bedrock so request_lane (while remaining.positive? loop) finds it
    write_test_lane(provider: :bedrock, model: 'claude-sonnet-4-6', tier: :cloud)
  end

  describe 'when pipeline_enabled is false' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = false
    end

    it 'uses single provider call and returns a Inference::Response' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call).and_return(native_dispatch_result(content: good_content))

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq(good_content)
    end

    it 'does not retry on quality failure' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call).and_return(native_dispatch_result(content: short_content))

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result.message[:content]).to eq(short_content)
    end
  end

  describe 'when pipeline_enabled is true' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = true
      register_fallback_provider
    end

    it 'returns a Inference::Response on first passing attempt' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call).and_return(native_dispatch_result(content: good_content))

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq(good_content)
    end

    it 'returns response on first successful dispatch (quality-based retry removed in P5 stateless loop)' do
      # P5: the while remaining.positive? loop retries on raised exceptions only.
      # Quality-score-based retry was part of the old chain machinery and is not part of
      # the new stateless loop. A low-quality response is returned as-is (no exception raised).
      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_return(native_dispatch_result(content: short_content))

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(Legion::LLM::Call::Dispatch).to have_received(:call).once
    end

    it 'retries on provider error and returns good response on second attempt' do
      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do
        call_count += 1
        raise Legion::LLM::ProviderError, 'timeout' if call_count == 1

        native_dispatch_result(content: good_content)
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq(good_content)
      expect(call_count).to eq(2)
    end

    it 'retries streaming provider errors through the escalation chain' do
      streaming_request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { provider: :bedrock, model: 'claude-sonnet-4-6' },
        stream:   true
      )

      chunk = Struct.new(:content).new(good_content)
      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do |provider:, **, &block|
        call_count += 1
        raise Legion::LLM::ProviderError, 'does not support tools' if provider == :bedrock

        block&.call(chunk)
        native_dispatch_result(content: good_content)
      end

      streamed_chunks = []
      result = Legion::LLM::Inference::Executor.new(streaming_request).call_stream do |stream_chunk|
        streamed_chunks << stream_chunk.content
      end

      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq(good_content)
      expect(streamed_chunks).to eq([good_content])
      expect(call_count).to eq(2)
      expect(result.routing[:provider]).to eq(:anthropic)
    end

    it 'raises EscalationExhausted when all attempts fail' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do
        raise Legion::LLM::ProviderError, 'always fails'
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      expect { executor.call }.to raise_error(Legion::LLM::Errors::EscalationExhausted)
    end

    it 'respects max_attempts setting' do
      Legion::Settings[:llm][:routing][:escalation][:max_attempts] = 2

      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do
        call_count += 1
        raise Legion::LLM::ProviderError, 'fail'
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      expect { executor.call }.to raise_error(Legion::LLM::Errors::EscalationExhausted)
      expect(call_count).to be <= 2
    end

    it 'records timeline events for successful dispatch' do
      # P5: stateless loop records one escalation:attempt event per dispatch.
      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_return(native_dispatch_result(content: good_content))

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call

      escalation_events = result.timeline.select { |e| e[:key] == 'escalation:attempt' }
      expect(escalation_events.size).to be >= 1
    end

    it 'does not trip circuit breaker on plain dispatch (only on account_specific errors)' do
      # P5: circuit breaker is only tripped by account_specific errors, never by plain responses.
      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_return(native_dispatch_result(content: short_content))

      executor = Legion::LLM::Inference::Executor.new(request)
      executor.call

      expect(Legion::LLM::Call::Dispatch).to have_received(:call).once
    end

    it 'quality_check extra is available on the request but does not drive retry in P5 stateless loop' do
      # P5: quality_check drove retry in the old chain machinery; the new loop is exception-driven.
      # The extra value is still accessible but has no effect on dispatch retry logic.
      request_with_check = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { provider: :bedrock, model: 'claude-sonnet-4-6' },
        extra:    { quality_check: ->(r) { r.text.include?('SELECT') } }
      )

      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_return(native_dispatch_result(content: 'no SELECT here'))

      executor = Legion::LLM::Inference::Executor.new(request_with_check)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(Legion::LLM::Call::Dispatch).to have_received(:call).once
    end

    it 'does not escalate when escalation settings are absent' do
      Legion::Settings[:llm][:routing] = {
        enabled:    false,
        rules:      [],
        escalation: { pipeline_enabled: false }
      }

      expect(Legion::LLM::Call::Dispatch).to receive(:call).and_return(native_dispatch_result(content: good_content))

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end
end
