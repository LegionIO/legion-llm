# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm'
require 'legion/llm/quality/checker'
require 'legion/llm/router/escalation/history'
require 'legion/llm/router/escalation/chain'

RSpec.describe 'Legion::LLM.chat escalation' do
  let(:good_content) { 'This is a sufficiently long and varied response that passes all quality checks easily' }
  let(:short_content) { 'ok' }

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
                                  escalation:     { enabled: true, max_attempts: 3, quality_threshold: 50 },
                                  rules:          []
                                }
                              })
    # Register multiple providers so the chain has real fallbacks to iterate over
    %i[bedrock anthropic].each do |prov|
      model = prov == :bedrock ? 'claude-sonnet-4-6' : 'claude-opus-4-7'
      Legion::LLM::Call::Registry.register(prov, Module.new do
        define_singleton_method(:offerings) { [{ model: model }] }
      end, metadata: { default_model: model })
    end
  end

  describe 'with escalate: false' do
    it 'dispatches once through the native provider' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call).and_return(native_dispatch_result(content: good_content))
      result = Legion::LLM.chat(escalate: false, message: 'test')
      expect(result.content).to eq(good_content)
    end
  end

  describe 'with escalate: true and hard failure then success' do
    it 'retries on exception and returns successful response' do
      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do
        call_count += 1
        raise Legion::LLM::ProviderError, 'API timeout' if call_count == 1

        native_dispatch_result(content: good_content)
      end

      response = Legion::LLM.chat(escalate: true, message: 'test')
      expect(response.content).to eq(good_content)
    end
  end

  describe 'with escalate: true and quality failure then success' do
    it 'retries on quality failure and returns good response' do
      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do
        call_count += 1
        if call_count == 1
          native_dispatch_result(content: short_content)
        else
          native_dispatch_result(content: good_content)
        end
      end

      response = Legion::LLM.chat(escalate: true, message: 'test')
      expect(response.content).to eq(good_content)
    end
  end

  describe 'with escalate: true and all failures' do
    it 'raises EscalationExhausted after exhausting chain' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do
        raise Legion::LLM::ProviderError, 'fail'
      end

      expect do
        Legion::LLM.chat(escalate: true, message: 'test')
      end.to raise_error(Legion::LLM::EscalationExhausted)
    end
  end

  describe 'with custom quality_check' do
    it 'uses custom check for quality assessment' do
      call_count = 0
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do
        call_count += 1
        if call_count == 1
          native_dispatch_result(content: 'no sql here but long enough to pass basic checks yeah')
        else
          native_dispatch_result(content: 'SELECT * FROM users WHERE active = true padding text here')
        end
      end

      custom = ->(r) { r.content.include?('SELECT') }
      response = Legion::LLM.chat(escalate: true, message: 'test', quality_check: custom)
      expect(response.content).to include('SELECT')
    end
  end

  describe 'without escalation enabled' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:enabled] = false
    end

    it 'defaults escalate to false and returns a native response' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call).and_return(native_dispatch_result(content: good_content))
      result = Legion::LLM.chat(message: 'test')
      expect(result.content).to eq(good_content)
    end
  end
end
