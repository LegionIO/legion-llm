# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM OpenInference instrumentation' do
  before do
    stub_const('Legion::Telemetry::OpenInference', Module.new do
      def self.open_inference_enabled?
        false
      end

      def self.llm_span(**) = yield(nil)

      def self.embedding_span(**) = yield(nil)
    end)
  end

  describe '.chat' do
    it 'wraps call in llm_span when OpenInference is available' do
      allow(Legion::Telemetry::OpenInference).to receive(:open_inference_enabled?).and_return(true)
      expect(Legion::Telemetry::OpenInference).to receive(:llm_span).and_yield(nil)
      allow(Legion::LLM).to receive(:chat_direct).and_return(double(model: 'test'))

      Legion::LLM.chat(message: 'test', model: 'test-model')
    end

    it 'works normally when OpenInference is not loaded' do
      hide_const('Legion::Telemetry::OpenInference')
      allow(Legion::LLM).to receive(:chat_direct).and_return(double(model: 'test'))
      result = Legion::LLM.chat(message: 'test')
      expect(result).not_to be_nil
    end
  end

  describe '.embed' do
    it 'wraps call in embedding_span when OpenInference is available' do
      allow(Legion::Telemetry::OpenInference).to receive(:open_inference_enabled?).and_return(true)
      expect(Legion::Telemetry::OpenInference).to receive(:embedding_span).and_yield(nil)
      allow(Legion::LLM).to receive(:embed_direct).and_return({ vector: [0.1] })

      Legion::LLM.embed('test text')
    end
  end

  describe '.structured' do
    it 'wraps call in llm_span when OpenInference is available' do
      allow(Legion::Telemetry::OpenInference).to receive(:open_inference_enabled?).and_return(true)
      expect(Legion::Telemetry::OpenInference).to receive(:llm_span).and_yield(nil)
      allow(Legion::LLM).to receive(:structured_direct).and_return({ score: 0.9 })

      Legion::LLM.structured(messages: 'test', schema: {})
    end
  end
end
