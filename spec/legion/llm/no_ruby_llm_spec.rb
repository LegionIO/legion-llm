# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/openai/chat_completions'
require 'legion/llm/api/anthropic/messages'

RSpec.describe 'no RubyLLM compatibility behavior' do
  before do
    hide_const('RubyLLM') if defined?(RubyLLM)
    allow(Legion::LLM).to receive(:ruby_llm_available?).and_return(false)
  end

  describe 'non-pipeline chat' do
    before do
      Legion::Settings[:llm][:pipeline_enabled] = false
      Legion::LLM::Call::Registry.reset!
    end

    after { Legion::LLM::Call::Registry.reset! }

    it 'routes message-style calls through a registered native provider' do
      native_provider = Module.new do
        module_function

        def chat(model:, messages:, **)
          { content: "native #{model}: #{messages.last[:content]}", usage: { input_tokens: 2, output_tokens: 3 } }
        end
      end
      Legion::LLM::Call::Registry.register(:native_test, native_provider)

      response = Legion::LLM.chat(message: 'hello', model: 'native-model', provider: :native_test)

      expect(response).to be_a(Legion::LLM::Call::NativeResponseAdapter)
      expect(response.content).to eq('native native-model: hello')
      expect(response.input_tokens).to eq(2)
      expect(response.output_tokens).to eq(3)
    end

    it 'raises ProviderError for RubyLLM-only session-style calls' do
      expect do
        Legion::LLM.chat(model: 'native-model', provider: :native_test)
      end.to raise_error(Legion::LLM::ProviderError, /RubyLLM is unavailable/)
    end

    it 'raises ProviderError when no native provider is registered' do
      expect do
        Legion::LLM.chat(message: 'hello', model: 'native-model', provider: :missing_native, escalate: false)
      end.to raise_error(Legion::LLM::ProviderError, /native provider/)
    end
  end

  describe 'provider probes' do
    it 'skips model-list probes without touching RubyLLM constants' do
      expect(Legion::LLM::Call::Providers.probe_via_model_list(:openai, 'gpt-4o')).to eq(:unavailable)
    end

    it 'skips chat probes without touching RubyLLM constants' do
      expect(Legion::LLM::Call::Providers.probe_via_chat(:openai, 'gpt-4o')).to eq(:unavailable)
    end
  end

  describe 'escalation exhaustion' do
    it 'raises EscalationExhausted when native attempts fail without RubyLLM' do
      native_provider = Module.new do
        module_function

        def chat(**)
          raise Legion::LLM::ProviderError, 'native failed'
        end
      end
      Legion::LLM::Call::Registry.register(:native_test, native_provider)

      resolution = Legion::LLM::Router::Resolution.new(
        tier: :local, provider: :native_test, model: 'native-model'
      )
      chain = Legion::LLM::Router::EscalationChain.new(resolutions: [resolution], max_attempts: 1)
      allow(Legion::LLM::Router).to receive(:resolve_chain).and_return(chain)

      expect do
        Legion::LLM::Inference.send(
          :chat_with_escalation,
          model:           'native-model',
          provider:        :native_test,
          intent:          nil,
          tier:            nil,
          max_escalations: 1,
          quality_check:   nil,
          message:         'hello'
        )
      end.to raise_error(Legion::LLM::EscalationExhausted, /without RubyLLM/)
    end
  end

  describe 'API tool class builders' do
    it 'omits OpenAI compatibility tool classes' do
      tools = [{ name: 'lookup', description: 'Lookup', parameters: { properties: { query: { type: 'string' } } } }]

      expect(Legion::LLM::API::OpenAI::ChatCompletions.build_openai_tool_classes(tools)).to eq([])
    end

    it 'omits Anthropic compatibility tool classes' do
      tools = [{ name: 'lookup', description: 'Lookup', parameters: { properties: { query: { type: 'string' } } } }]

      expect(Legion::LLM::API::Anthropic::Messages.send(:build_tool_classes, tools)).to eq([])
    end
  end
end
