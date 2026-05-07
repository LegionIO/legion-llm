# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/translators/openai_response'

RSpec.describe Legion::LLM::API::Translators::OpenAIResponse do
  describe '.format_embeddings' do
    it 'uses provider usage when embedding tokens are available' do
      response = described_class.format_embeddings(
        [0.1, 0.2],
        model:      'text-embedding-3-small',
        input_text: 'one two three',
        usage:      { prompt_tokens: 42, total_tokens: 42 }
      )

      expect(response[:usage]).to eq(prompt_tokens: 42, total_tokens: 42)
    end
  end
end
