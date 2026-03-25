# frozen_string_literal: true

RSpec.describe Legion::LLM::ToolRegistry do
  before { described_class.clear }

  let(:tool_a) { Class.new }
  let(:tool_b) { Class.new }

  describe '.register' do
    it 'adds a tool class' do
      described_class.register(tool_a)
      expect(described_class.tools).to include(tool_a)
    end

    it 'deduplicates identical registrations' do
      described_class.register(tool_a)
      described_class.register(tool_a)
      expect(described_class.tools.count { |t| t == tool_a }).to eq(1)
    end

    it 'accepts multiple distinct tools' do
      described_class.register(tool_a)
      described_class.register(tool_b)
      expect(described_class.tools).to contain_exactly(tool_a, tool_b)
    end
  end

  describe '.tools' do
    it 'returns a dup, not the internal array' do
      described_class.register(tool_a)
      snapshot = described_class.tools
      snapshot << tool_b
      expect(described_class.tools).not_to include(tool_b)
    end

    it 'returns empty array when nothing registered' do
      expect(described_class.tools).to eq([])
    end
  end

  describe '.clear' do
    it 'empties the registry' do
      described_class.register(tool_a)
      described_class.clear
      expect(described_class.tools).to be_empty
    end
  end

  describe 'thread safety' do
    it 'handles concurrent register and tools calls without raising' do
      threads = 10.times.map do |_i|
        Thread.new do
          tool = Class.new
          described_class.register(tool)
          described_class.tools
        end
      end
      expect { threads.each(&:join) }.not_to raise_error
    end
  end
end
