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
      define_singleton_method(:offerings) { [{ model: 'claude-opus-4-7' }] }
    end, metadata: { default_model: 'claude-opus-4-7' })
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
    # Register bedrock in the registry so build_default_escalation_chain has a primary resolution
    Legion::LLM::Call::Registry.register(:bedrock, Module.new do
      define_singleton_method(:offerings) { [{ model: 'claude-sonnet-4-6' }] }
    end, metadata: { default_model: 'claude-sonnet-4-6' })
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

    it 'retries on quality failure and returns good response on second attempt' do
      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do
        call_count += 1
        if call_count == 1
          native_dispatch_result(content: short_content)
        else
          native_dispatch_result(content: good_content)
        end
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq(good_content)
      expect(call_count).to eq(2)
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
      expect { executor.call }.to raise_error(Legion::LLM::EscalationExhausted)
    end

    it 'respects max_attempts setting' do
      Legion::Settings[:llm][:routing][:escalation][:max_attempts] = 2

      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do
        call_count += 1
        raise Legion::LLM::ProviderError, 'fail'
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      expect { executor.call }.to raise_error(Legion::LLM::EscalationExhausted)
      expect(call_count).to be <= 2
    end

    it 'records timeline events for each escalation attempt' do
      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do
        call_count += 1
        if call_count == 1
          native_dispatch_result(content: short_content)
        else
          native_dispatch_result(content: good_content)
        end
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call

      escalation_events = result.timeline.select { |e| e[:key] == 'escalation:attempt' }
      expect(escalation_events.size).to be >= 2
    end

    it 'logs quality failures without affecting circuit breaker during escalation' do
      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do
        call_count += 1
        call_count == 1 ? native_dispatch_result(content: short_content) : native_dispatch_result(content: good_content)
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      allow(executor).to receive(:log).and_return(Legion::Logging.log)
      executor.call

      expect(call_count).to be >= 1
    end

    it 'uses custom quality_check from request extra when present' do
      request_with_check = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { provider: :bedrock, model: 'claude-sonnet-4-6' },
        extra:    { quality_check: ->(r) { r.content.include?('SELECT') } }
      )

      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do
        call_count += 1
        if call_count == 1
          native_dispatch_result(content: 'this response is long enough but lacks the keyword padding here')
        else
          native_dispatch_result(content: 'SELECT * FROM users WHERE active = true and this is long enough')
        end
      end

      executor = Legion::LLM::Inference::Executor.new(request_with_check)
      result = executor.call
      expect(result.message[:content]).to include('SELECT')
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
