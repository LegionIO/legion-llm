# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM gateway integration' do
  let(:response_double) do
    double('response',
           input_tokens:    100,
           output_tokens:   50,
           thinking_tokens: 10,
           provider:        'anthropic',
           model:           'claude-opus-4-6')
  end

  describe '.chat' do
    context 'when gateway is loaded' do
      before do
        gateway_inference = Module.new do
          def self.chat(**); end
        end

        stub_const('Legion::Extensions::LLM::Gateway::Runners::Inference', gateway_inference)
        allow(gateway_inference).to receive(:chat).and_return(response_double)
      end

      it 'delegates to gateway when message is provided' do
        result = Legion::LLM.chat(message: 'hello', model: 'test')
        expect(result).to eq(response_double)
        expect(Legion::Extensions::LLM::Gateway::Runners::Inference).to have_received(:chat)
      end

      it 'falls back to direct when message is nil' do
        allow(RubyLLM).to receive(:chat).and_return(response_double)
        Legion::LLM.chat(model: 'test')
        expect(Legion::Extensions::LLM::Gateway::Runners::Inference).not_to have_received(:chat)
      end
    end

    context 'when gateway is not loaded' do
      before do
        hide_const('Legion::Extensions::LLM::Gateway::Runners::Inference')
      end

      it 'falls back to direct chat' do
        allow(RubyLLM).to receive(:chat).and_return(response_double)
        result = Legion::LLM.chat(model: 'test')
        expect(result).to eq(response_double)
      end
    end
  end

  describe '.chat_direct' do
    it 'bypasses gateway even when loaded' do
      gateway_inference = Module.new do
        def self.chat(**); end
      end
      stub_const('Legion::Extensions::LLM::Gateway::Runners::Inference', gateway_inference)
      allow(gateway_inference).to receive(:chat)
      allow(RubyLLM).to receive(:chat).and_return(response_double)

      Legion::LLM.chat_direct(model: 'test')
      expect(gateway_inference).not_to have_received(:chat)
    end
  end

  describe '.embed' do
    context 'when gateway is loaded' do
      before do
        gateway_inference = Module.new do
          def self.embed(**); end
        end
        stub_const('Legion::Extensions::LLM::Gateway::Runners::Inference', gateway_inference)
        allow(gateway_inference).to receive(:embed).and_return({ vector: [0.1] })
      end

      it 'delegates to gateway' do
        result = Legion::LLM.embed('hello')
        expect(result).to eq({ vector: [0.1] })
      end
    end

    context 'when gateway is not loaded' do
      before { hide_const('Legion::Extensions::LLM::Gateway::Runners::Inference') }

      it 'falls back to direct embed' do
        require 'legion/llm/embeddings'
        allow(Legion::LLM::Embeddings).to receive(:generate).and_return({ vector: [0.2] })
        result = Legion::LLM.embed('hello')
        expect(result).to eq({ vector: [0.2] })
      end
    end
  end

  describe '.structured' do
    context 'when gateway is loaded' do
      before do
        gateway_inference = Module.new do
          def self.structured(**); end
        end
        stub_const('Legion::Extensions::LLM::Gateway::Runners::Inference', gateway_inference)
        allow(gateway_inference).to receive(:structured).and_return({ data: {} })
      end

      it 'delegates to gateway' do
        result = Legion::LLM.structured(messages: [], schema: {})
        expect(result).to eq({ data: {} })
      end
    end

    context 'when gateway is not loaded' do
      before { hide_const('Legion::Extensions::LLM::Gateway::Runners::Inference') }

      it 'falls back to direct structured' do
        require 'legion/llm/structured_output'
        allow(Legion::LLM::StructuredOutput).to receive(:generate).and_return({ data: {} })
        result = Legion::LLM.structured(messages: [], schema: {})
        expect(result).to eq({ data: {} })
      end
    end
  end
end
