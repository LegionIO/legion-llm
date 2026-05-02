# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm'
require 'legion/llm/quality/checker'
require 'legion/llm/router/escalation/chain'

RSpec.describe 'Pipeline escalation via step_provider_call' do
  let(:good_content) { 'This is a sufficiently long and varied response that passes all quality checks easily' }
  let(:short_content) { 'ok' }

  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :bedrock, model: 'claude-sonnet-4-6' }
    )
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
  end

  describe 'when pipeline_enabled is false' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = false
    end

    it 'uses single provider call and returns a Inference::Response' do
      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat).and_return(native_dispatch_result(content: good_content))

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq(good_content)
    end

    it 'does not retry on quality failure' do
      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat).and_return(native_dispatch_result(content: short_content))

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result.message[:content]).to eq(short_content)
    end
  end

  describe 'when pipeline_enabled is true' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = true
    end

    it 'returns a Inference::Response on first passing attempt' do
      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat).and_return(native_dispatch_result(content: good_content))

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq(good_content)
    end

    it 'retries on quality failure and returns good response on second attempt' do
      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat) do
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
      allow(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat) do
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

    it 'raises EscalationExhausted when all attempts fail' do
      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat) do
        call_count += 1
        raise Legion::LLM::ProviderError, 'always fails'
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      expect { executor.call }.to raise_error(Legion::LLM::EscalationExhausted)
    end

    it 'respects max_attempts setting' do
      Legion::Settings[:llm][:routing][:escalation][:max_attempts] = 2

      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat) do
        call_count += 1
        raise Legion::LLM::ProviderError, 'fail'
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      expect { executor.call }.to raise_error(Legion::LLM::EscalationExhausted)
      expect(call_count).to eq(2)
    end

    it 'records timeline events for each escalation attempt' do
      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat) do
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
      expect(escalation_events.size).to eq(2)
    end

    it 'uses custom quality_check from request extra when present' do
      request_with_check = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { provider: :bedrock, model: 'claude-sonnet-4-6' },
        extra:    { quality_check: ->(r) { r.content.include?('SELECT') } }
      )

      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat) do
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

      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat).and_return(native_dispatch_result(content: good_content))

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end
end
