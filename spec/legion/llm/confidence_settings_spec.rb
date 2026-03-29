# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Settings do
  subject(:defaults) { described_class.default }

  describe '.confidence_defaults' do
    subject(:conf) { described_class.confidence_defaults }

    it 'returns a hash' do
      expect(conf).to be_a(Hash)
    end

    it 'includes a :bands key' do
      expect(conf).to have_key(:bands)
    end

    it 'bands has :low boundary at 0.3' do
      expect(conf[:bands][:low]).to eq(0.3)
    end

    it 'bands has :medium boundary at 0.5' do
      expect(conf[:bands][:medium]).to eq(0.5)
    end

    it 'bands has :high boundary at 0.7' do
      expect(conf[:bands][:high]).to eq(0.7)
    end

    it 'bands has :very_high boundary at 0.9' do
      expect(conf[:bands][:very_high]).to eq(0.9)
    end
  end

  describe '.default' do
    it 'includes a :confidence key' do
      expect(defaults).to have_key(:confidence)
    end

    it 'confidence key equals confidence_defaults' do
      expect(defaults[:confidence]).to eq(described_class.confidence_defaults)
    end
  end
end
