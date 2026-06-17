# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Capabilities do
  describe '.normalize' do
    it 'replaces aliases with their canonical capability' do
      result = described_class.normalize(%i[function_calling tool_use stream])
      expect(result).to contain_exactly(:tools, :streaming)
    end

    it 'handles string inputs' do
      result = described_class.normalize(%w[Function_Calling Stream])
      expect(result).to contain_exactly(:tools, :streaming)
    end

    it 'returns empty for nil' do
      expect(described_class.normalize(nil)).to eq([])
    end
  end

  describe '.include_all?' do
    it 'matches via aliases' do
      expect(described_class.include_all?(%i[completion function_calling], [:tools])).to be true
    end

    it 'matches when required uses an alias and available uses the canonical' do
      expect(described_class.include_all?(%i[tools], [:function_calling])).to be true
    end

    it 'returns false when capability is absent' do
      expect(described_class.include_all?(%i[completion streaming], [:tools])).to be false
    end

    it 'returns false for empty available' do
      expect(described_class.include_all?([], [:tools])).to be false
    end

    it 'returns true for empty required' do
      expect(described_class.include_all?(%i[streaming], [])).to be true
    end
  end

  describe '.merge' do
    it 'merges multiple capability sets with dedup' do
      result = described_class.merge(%i[completion function_calling], %i[streaming tool_use])
      expect(result).to include(:completion, :tools, :streaming)
      expect(result.uniq).to eq(result)
    end
  end
end
