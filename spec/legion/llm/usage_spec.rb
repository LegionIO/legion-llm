# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/metering/usage'

RSpec.describe Legion::LLM::Usage do
  describe 'defaults' do
    subject(:usage) { described_class.new }

    it 'defaults input_tokens to 0' do
      expect(usage.input_tokens).to eq(0)
    end

    it 'defaults output_tokens to 0' do
      expect(usage.output_tokens).to eq(0)
    end

    it 'defaults cache_read_tokens to 0' do
      expect(usage.cache_read_tokens).to eq(0)
    end

    it 'defaults cache_write_tokens to 0' do
      expect(usage.cache_write_tokens).to eq(0)
    end

    it 'auto-calculates total_tokens as input + output when not provided' do
      expect(usage.total_tokens).to eq(0)
    end
  end

  describe 'total_tokens auto-calculation' do
    it 'sums input and output when total_tokens is not provided' do
      usage = described_class.new(input_tokens: 100, output_tokens: 50)
      expect(usage.total_tokens).to eq(150)
    end

    it 'uses explicit total_tokens when provided' do
      usage = described_class.new(input_tokens: 100, output_tokens: 50, total_tokens: 200)
      expect(usage.total_tokens).to eq(200)
    end

    it 'auto-calculates correctly when only input_tokens is provided' do
      usage = described_class.new(input_tokens: 300)
      expect(usage.total_tokens).to eq(300)
    end

    it 'auto-calculates correctly when only output_tokens is provided' do
      usage = described_class.new(output_tokens: 75)
      expect(usage.total_tokens).to eq(75)
    end
  end

  describe 'cache fields' do
    it 'stores cache_read_tokens' do
      usage = described_class.new(input_tokens: 500, output_tokens: 100, cache_read_tokens: 400)
      expect(usage.cache_read_tokens).to eq(400)
    end

    it 'stores cache_write_tokens' do
      usage = described_class.new(input_tokens: 500, output_tokens: 100, cache_write_tokens: 500)
      expect(usage.cache_write_tokens).to eq(500)
    end

    it 'stores both cache fields together' do
      usage = described_class.new(
        input_tokens:       200,
        output_tokens:      80,
        cache_read_tokens:  150,
        cache_write_tokens: 200
      )
      expect(usage.cache_read_tokens).to eq(150)
      expect(usage.cache_write_tokens).to eq(200)
    end
  end

  describe 'explicit total_tokens override' do
    it 'preserves an explicit total that differs from input + output' do
      usage = described_class.new(input_tokens: 10, output_tokens: 10, total_tokens: 999)
      expect(usage.total_tokens).to eq(999)
    end

    it 'preserves an explicit total of zero' do
      usage = described_class.new(total_tokens: 0)
      expect(usage.total_tokens).to eq(0)
    end
  end

  describe 'freezing behavior' do
    it 'is frozen after construction (::Data.define produces frozen instances)' do
      usage = described_class.new(input_tokens: 10, output_tokens: 20)
      expect(usage).to be_frozen
    end

    it 'raises FrozenError when attempting to mutate' do
      usage = described_class.new(input_tokens: 10)
      expect { usage.instance_variable_set(:@input_tokens, 99) }.to raise_error(FrozenError)
    end
  end

  describe 'equality' do
    it 'is equal to another instance with the same field values' do
      a = described_class.new(input_tokens: 10, output_tokens: 20)
      b = described_class.new(input_tokens: 10, output_tokens: 20)
      expect(a).to eq(b)
    end

    it 'is not equal when any field differs' do
      a = described_class.new(input_tokens: 10, output_tokens: 20)
      b = described_class.new(input_tokens: 10, output_tokens: 21)
      expect(a).not_to eq(b)
    end
  end

  describe '#to_h' do
    it 'returns a hash with all five fields' do
      usage = described_class.new(
        input_tokens:       100,
        output_tokens:      50,
        cache_read_tokens:  10,
        cache_write_tokens: 5
      )
      h = usage.to_h
      expect(h).to include(
        input_tokens:       100,
        output_tokens:      50,
        cache_read_tokens:  10,
        cache_write_tokens: 5,
        total_tokens:       150
      )
    end
  end
end
