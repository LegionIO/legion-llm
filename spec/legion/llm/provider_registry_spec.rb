# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Call::Registry do
  before { described_class.reset! }

  let(:fake_ext_a) { Module.new }
  let(:fake_ext_b) { Module.new }

  describe '.register' do
    it 'stores an extension under a symbol key' do
      described_class.register(:claude, fake_ext_a)
      expect(described_class.for(:claude)).to eq(fake_ext_a)
    end

    it 'coerces string names to symbols on register' do
      described_class.register('bedrock', fake_ext_a)
      expect(described_class.for(:bedrock)).to eq(fake_ext_a)
    end

    it 'overwrites a previous registration for the same name' do
      described_class.register(:claude, fake_ext_a)
      described_class.register(:claude, fake_ext_b)
      expect(described_class.for(:claude)).to eq(fake_ext_b)
    end

    it 'returns the extension module' do
      result = described_class.register(:openai, fake_ext_a)
      expect(result).to eq(fake_ext_a)
    end
  end

  describe '.for' do
    it 'returns nil when provider is not registered' do
      expect(described_class.for(:nonexistent)).to be_nil
    end

    it 'coerces string name to symbol on lookup' do
      described_class.register(:anthropic, fake_ext_a)
      expect(described_class.for('anthropic')).to eq(fake_ext_a)
    end

    it 'returns the registered extension module' do
      described_class.register(:gemini, fake_ext_b)
      expect(described_class.for(:gemini)).to eq(fake_ext_b)
    end
  end

  describe '.available' do
    it 'returns empty array when nothing is registered' do
      expect(described_class.available).to eq([])
    end

    it 'returns all registered provider names as symbols' do
      described_class.register(:claude, fake_ext_a)
      described_class.register(:bedrock, fake_ext_b)
      expect(described_class.available).to contain_exactly(:claude, :bedrock)
    end

    it 'returns a dup — mutations do not affect the registry' do
      described_class.register(:claude, fake_ext_a)
      snapshot = described_class.available
      snapshot << :injected
      expect(described_class.available).not_to include(:injected)
    end
  end

  describe '.registered?' do
    it 'returns true when provider is registered' do
      described_class.register(:bedrock, fake_ext_a)
      expect(described_class.registered?(:bedrock)).to be true
    end

    it 'returns false when provider is not registered' do
      expect(described_class.registered?(:missing)).to be false
    end

    it 'coerces string name to symbol' do
      described_class.register(:openai, fake_ext_a)
      expect(described_class.registered?('openai')).to be true
    end
  end

  describe '.reset!' do
    it 'clears all registrations' do
      described_class.register(:claude, fake_ext_a)
      described_class.register(:bedrock, fake_ext_b)
      described_class.reset!
      expect(described_class.available).to be_empty
    end
  end

  describe 'thread safety' do
    it 'handles concurrent register and lookup calls without raising' do
      threads = 20.times.map do |i|
        Thread.new do
          described_class.register(:"provider_#{i}", Module.new)
          described_class.for(:"provider_#{i}")
          described_class.available
        end
      end
      expect { threads.each(&:join) }.not_to raise_error
    end
  end
end
