# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Fleet::Handler do
  describe '.require_auth?' do
    it 'returns false by default' do
      expect(described_class.require_auth?).to eq(false)
    end

    it 'returns true when configured' do
      Legion::Settings[:llm][:routing] = { fleet: { require_auth: true } }
      expect(described_class.require_auth?).to eq(true)
    end
  end

  describe '.build_response' do
    it 'builds response hash from correlation_id and response object' do
      response = double(input_tokens: 10, output_tokens: 5, thinking_tokens: 0,
                        provider: :anthropic, model: 'claude-opus-4-6')
      result = described_class.build_response('corr-123', response)
      expect(result[:correlation_id]).to eq('corr-123')
      expect(result[:input_tokens]).to eq(10)
      expect(result[:output_tokens]).to eq(5)
      expect(result[:provider]).to eq(:anthropic)
    end

    it 'handles responses without token methods' do
      response = { content: 'hello' }
      result = described_class.build_response('corr-123', response)
      expect(result[:correlation_id]).to eq('corr-123')
      expect(result[:input_tokens]).to eq(0)
    end
  end

  describe '.valid_token?' do
    it 'returns true when auth not required' do
      expect(described_class.valid_token?(nil)).to eq(true)
    end
  end
end
