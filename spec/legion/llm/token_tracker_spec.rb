# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Metering::Tokens do
  before(:each) { described_class.reset! }

  describe '.record' do
    it 'returns an entry hash with token counts and timestamp' do
      entry = described_class.record(input_tokens: 100, output_tokens: 50)
      expect(entry[:input_tokens]).to eq(100)
      expect(entry[:output_tokens]).to eq(50)
      expect(entry[:recorded_at]).to be_a(Time)
    end

    it 'coerces string-like values to integers' do
      entry = described_class.record(input_tokens: '200', output_tokens: '75')
      expect(entry[:input_tokens]).to eq(200)
      expect(entry[:output_tokens]).to eq(75)
    end

    it 'accumulates multiple records' do
      described_class.record(input_tokens: 100, output_tokens: 50)
      described_class.record(input_tokens: 200, output_tokens: 100)
      expect(described_class.total_tokens).to eq(450)
    end
  end

  describe '.total_tokens' do
    it 'returns 0 when no tokens recorded' do
      expect(described_class.total_tokens).to eq(0)
    end

    it 'returns sum of all input + output tokens' do
      described_class.record(input_tokens: 300, output_tokens: 100)
      described_class.record(input_tokens: 50,  output_tokens: 25)
      expect(described_class.total_tokens).to eq(475)
    end
  end

  describe '.total_input_tokens' do
    it 'returns sum of input tokens only' do
      described_class.record(input_tokens: 100, output_tokens: 200)
      described_class.record(input_tokens: 50,  output_tokens: 75)
      expect(described_class.total_input_tokens).to eq(150)
    end
  end

  describe '.total_output_tokens' do
    it 'returns sum of output tokens only' do
      described_class.record(input_tokens: 100, output_tokens: 200)
      described_class.record(input_tokens: 50,  output_tokens: 75)
      expect(described_class.total_output_tokens).to eq(275)
    end
  end

  describe '.session_exceeded?' do
    it 'returns false when no limit is configured' do
      described_class.record(input_tokens: 999_999, output_tokens: 999_999)
      expect(described_class.session_exceeded?).to be false
    end

    it 'returns false when total is below the limit' do
      Legion::Settings[:llm][:budget] = { session_max_tokens: 1000 }
      described_class.record(input_tokens: 300, output_tokens: 200)
      expect(described_class.session_exceeded?).to be false
    end

    it 'returns true when total equals the limit' do
      Legion::Settings[:llm][:budget] = { session_max_tokens: 500 }
      described_class.record(input_tokens: 300, output_tokens: 200)
      expect(described_class.session_exceeded?).to be true
    end

    it 'returns true when total exceeds the limit' do
      Legion::Settings[:llm][:budget] = { session_max_tokens: 100 }
      described_class.record(input_tokens: 80, output_tokens: 80)
      expect(described_class.session_exceeded?).to be true
    end
  end

  describe '.session_warning?' do
    it 'returns false when no warn threshold is configured' do
      described_class.record(input_tokens: 999_999, output_tokens: 999_999)
      expect(described_class.session_warning?).to be false
    end

    it 'returns false when total is below the warning threshold' do
      Legion::Settings[:llm][:budget] = { session_warn_tokens: 1000 }
      described_class.record(input_tokens: 300, output_tokens: 200)
      expect(described_class.session_warning?).to be false
    end

    it 'returns true when total reaches the warning threshold' do
      Legion::Settings[:llm][:budget] = { session_warn_tokens: 500 }
      described_class.record(input_tokens: 300, output_tokens: 200)
      expect(described_class.session_warning?).to be true
    end
  end

  describe '.reset!' do
    it 'clears all accumulated token records' do
      described_class.record(input_tokens: 1000, output_tokens: 500)
      expect(described_class.total_tokens).to eq(1500)
      described_class.reset!
      expect(described_class.total_tokens).to eq(0)
    end
  end

  describe '.summary' do
    it 'returns a hash with all summary fields' do
      Legion::Settings[:llm][:budget] = { session_max_tokens: 1000, session_warn_tokens: 800 }
      described_class.record(input_tokens: 200, output_tokens: 100)

      s = described_class.summary
      expect(s[:total_tokens]).to eq(300)
      expect(s[:total_input_tokens]).to eq(200)
      expect(s[:total_output_tokens]).to eq(100)
      expect(s[:session_max_tokens]).to eq(1000)
      expect(s[:session_warn_tokens]).to eq(800)
      expect(s[:exceeded]).to be false
      expect(s[:warning]).to be false
      expect(s[:remaining]).to eq(700)
    end

    it 'sets remaining to nil when no limit configured' do
      s = described_class.summary
      expect(s[:remaining]).to be_nil
    end

    it 'sets remaining to 0 when budget is exceeded' do
      Legion::Settings[:llm][:budget] = { session_max_tokens: 100 }
      described_class.record(input_tokens: 60, output_tokens: 80)

      s = described_class.summary
      expect(s[:remaining]).to eq(0)
      expect(s[:exceeded]).to be true
    end
  end

  describe 'thread safety' do
    it 'accumulates correctly under concurrent writes' do
      threads = 10.times.map do
        Thread.new { described_class.record(input_tokens: 10, output_tokens: 5) }
      end
      threads.each(&:join)
      expect(described_class.total_tokens).to eq(150)
    end
  end
end
