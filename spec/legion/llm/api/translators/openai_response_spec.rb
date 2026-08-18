# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/translators/openai_response'

RSpec.describe Legion::LLM::API::Translators::OpenAIResponse do
  describe '.format_embeddings' do
    it 'renders one entry per input with sequential index in input order' do
      response = described_class.format_embeddings(
        [
          { vector: [0.1, 0.2] },
          { vector: [0.3, 0.4] },
          { vector: [0.5, 0.6] }
        ],
        model: 'text-embedding-3-small'
      )

      expect(response[:object]).to eq('list')
      expect(response[:model]).to eq('text-embedding-3-small')
      expect(response[:data].map { |e| e[:index] }).to eq([0, 1, 2])
      expect(response[:data].map { |e| e[:object] }).to all(eq('embedding'))
      expect(response[:data].map { |e| e[:embedding] }).to eq([[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]])
    end

    it 'accepts bare float arrays as entries' do
      response = described_class.format_embeddings([[0.1, 0.2]], model: 'm')
      expect(response[:data].first[:embedding]).to eq([0.1, 0.2])
      expect(response[:data].first[:index]).to eq(0)
    end

    it 'emits raw floats by default (encoding_format absent)' do
      response = described_class.format_embeddings([{ vector: [0.1, 0.2] }], model: 'm')
      expect(response[:data].first[:embedding]).to be_an(Array)
    end

    it 'emits a base64 string of little-endian float32 when encoding_format is base64' do
      # Every value is exactly representable in float32 so the round-trip
      # unpack is exact (0.1 is not float32-representable and would not survive
      # a double -> float32 -> double round-trip).
      vector = [0.5, -0.25, 3.75, 0.0]
      response = described_class.format_embeddings(
        [{ vector: vector }], model: 'm', encoding_format: 'base64'
      )

      encoded = response[:data].first[:embedding]
      expect(encoded).to be_a(String)

      raw = encoded.unpack1('m0')
      expect(raw).to eq(vector.pack('g*'))
      expect(raw.unpack('g*')).to eq(vector)
    end

    it 'uses provider token counts carried on the entries' do
      response = described_class.format_embeddings(
        [
          { vector: [0.1], tokens: 42 },
          { vector: [0.2], tokens: 7 }
        ],
        model:       'm',
        input_texts: %w[one two]
      )

      expect(response[:usage]).to eq(prompt_tokens: 49, total_tokens: 49)
    end

    it 'falls back to the input word count when no entry carries tokens' do
      response = described_class.format_embeddings(
        [{ vector: [0.1] }],
        model:       'm',
        input_texts: 'one two three'
      )

      expect(response[:usage]).to eq(prompt_tokens: 3, total_tokens: 3)
    end

    it 'falls back to summed word count for array inputs without tokens' do
      response = described_class.format_embeddings(
        [{ vector: [0.1] }, { vector: [0.2] }],
        model:       'm',
        input_texts: %w[one two three four]
      )

      expect(response[:usage]).to eq(prompt_tokens: 4, total_tokens: 4)
    end

    it 'uses provider usage when embedding tokens are available' do
      response = described_class.format_embeddings(
        [{ vector: [0.1, 0.2], tokens: 42 }],
        model: 'text-embedding-3-small'
      )

      expect(response[:usage]).to eq(prompt_tokens: 42, total_tokens: 42)
    end
  end
end
