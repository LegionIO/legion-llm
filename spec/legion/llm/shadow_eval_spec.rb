# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/shadow_eval'

RSpec.describe Legion::LLM::ShadowEval do
  describe '.enabled?' do
    it 'returns false when not configured' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :enabled).and_return(nil)
      expect(described_class.enabled?).to be false
    end

    it 'returns true when enabled' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :enabled).and_return(true)
      expect(described_class.enabled?).to be true
    end
  end

  describe '.should_sample?' do
    it 'returns false when disabled' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :enabled).and_return(false)
      expect(described_class.should_sample?).to be false
    end

    it 'samples based on rate when enabled' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :enabled).and_return(true)
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :sample_rate).and_return(1.0)
      expect(described_class.should_sample?).to be true
    end

    it 'never samples at rate 0' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :enabled).and_return(true)
      allow(Legion::Settings).to receive(:dig).with(:llm, :shadow, :sample_rate).and_return(0.0)
      expect(described_class.should_sample?).to be false
    end
  end

  describe '.compare' do
    it 'computes length ratio' do
      primary = { content: 'short', model: 'gpt-4o', usage: 10 }
      shadow = { content: 'also short text', model: 'gpt-4o-mini', usage: 5 }
      result = described_class.compare(primary, shadow, 'gpt-4o-mini')
      expect(result[:length_ratio]).to eq(15.0 / 5)
      expect(result[:primary_model]).to eq('gpt-4o')
      expect(result[:shadow_model]).to eq('gpt-4o-mini')
    end

    it 'handles nil content' do
      primary = { content: nil, model: 'gpt-4o', usage: 0 }
      shadow = { content: 'text', model: 'mini', usage: 0 }
      result = described_class.compare(primary, shadow, 'mini')
      expect(result[:length_ratio]).to eq(0.0)
    end
  end
end
