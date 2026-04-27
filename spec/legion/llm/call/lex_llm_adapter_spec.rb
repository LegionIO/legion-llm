# frozen_string_literal: true

require 'spec_helper'
require 'lex_llm'

RSpec.describe Legion::LLM::Call::LexLLMAdapter do
  let(:provider_class) do
    Class.new(LexLLM::Provider) do
      def api_base = 'https://adapter.invalid'

      def complete(_messages, model:, **)
        LexLLM::Message.new(role: :assistant, content: "hello #{model.id}", model_id: model.id,
                            input_tokens: 7, output_tokens: 3)
      end

      def embed(_text, model:, dimensions:)
        LexLLM::Embedding.new(vectors: Array.new(dimensions || 2, 0.5), model: model, input_tokens: 4)
      end
    end
  end

  let(:adapter) { described_class.new(:fake_llm, provider_class) }

  it 'maps chat dispatch to LexLLM provider completion' do
    result = adapter.chat(model: 'model-a', messages: [{ role: 'user', content: 'hi' }])

    expect(result[:result]).to eq('hello model-a')
    expect(result[:usage]).to include(input_tokens: 7, output_tokens: 3)
  end

  it 'maps embedding dispatch to LexLLM provider embeddings' do
    result = adapter.embed(model: 'embed-a', text: 'hello', dimensions: 3)

    expect(result[:result]).to eq([0.5, 0.5, 0.5])
    expect(result[:usage]).to include(input_tokens: 4, output_tokens: 0)
  end
end
