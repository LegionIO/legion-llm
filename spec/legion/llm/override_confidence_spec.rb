# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Tools::Confidence do
  before { described_class.reset! }

  describe '.record' do
    it 'stores override confidence for a tool' do
      described_class.record(
        tool:       'close_pr',
        lex:        'lex-github:PullRequest:close',
        confidence: 0.5
      )
      entry = described_class.lookup('close_pr')
      expect(entry[:confidence]).to eq(0.5)
    end

    it 'clamps confidence to 0.0-1.0' do
      described_class.record(tool: 'x', lex: 'lex-x:Y:z', confidence: 1.5)
      expect(described_class.lookup('x')[:confidence]).to eq(1.0)
    end

    it 'does not write override confidence to Legion::Data::Local' do
      stub_const('Legion::Data::Local', Class.new)
      allow(Legion::Data::Local).to receive(:upsert)

      described_class.record(tool: 'x', lex: 'lex-x:Y:z', confidence: 0.5)

      expect(Legion::Data::Local).not_to have_received(:upsert)
      expect(described_class.pending_l2_sync).to eq([])
    end
  end

  describe '.record_success / .record_failure' do
    it 'increases confidence on success' do
      described_class.record(tool: 'close_pr', lex: 'lex-github:PullRequest:close', confidence: 0.5)
      described_class.record_success('close_pr')
      entry = described_class.lookup('close_pr')
      expect(entry[:confidence]).to be > 0.5
      expect(entry[:hit_count]).to eq(1)
    end

    it 'decreases confidence on failure' do
      described_class.record(tool: 'close_pr', lex: 'lex-github:PullRequest:close', confidence: 0.5)
      described_class.record_failure('close_pr')
      entry = described_class.lookup('close_pr')
      expect(entry[:confidence]).to be < 0.5
      expect(entry[:miss_count]).to eq(1)
    end

    it 'ignores unknown tools' do
      expect { described_class.record_success('unknown') }.not_to raise_error
      expect { described_class.record_failure('unknown') }.not_to raise_error
    end

    it 'uses the configured success and failure deltas' do
      Legion::Settings[:llm][:tools][:confidence][:success_delta] = 0.2
      Legion::Settings[:llm][:tools][:confidence][:failure_delta] = -0.3
      described_class.record(tool: 'x', lex: 'lex-x:Y:z', confidence: 0.5)

      described_class.record_success('x')
      expect(described_class.lookup('x')[:confidence]).to eq(0.7)

      described_class.record_failure('x')
      expect(described_class.lookup('x')[:confidence]).to be_within(0.0001).of(0.4)
    end
  end

  describe '.should_override?' do
    it 'returns true when confidence >= 0.8' do
      described_class.record(tool: 'close_pr', lex: 'lex-github:PullRequest:close', confidence: 0.85)
      expect(described_class.should_override?('close_pr')).to eq(true)
    end

    it 'returns false when confidence < 0.8' do
      described_class.record(tool: 'close_pr', lex: 'lex-github:PullRequest:close', confidence: 0.5)
      expect(described_class.should_override?('close_pr')).to eq(false)
    end

    it 'returns false for unknown tools' do
      expect(described_class.should_override?('unknown')).to eq(false)
    end

    it 'uses the configured override threshold' do
      Legion::Settings[:llm][:tools][:confidence][:override_threshold] = 0.9
      described_class.record(tool: 'close_pr', lex: 'lex-github:PullRequest:close', confidence: 0.85)

      expect(described_class.should_override?('close_pr')).to eq(false)
    end
  end

  describe '.should_shadow?' do
    it 'returns true when confidence is 0.5-0.8' do
      described_class.record(tool: 'close_pr', lex: 'lex-github:PullRequest:close', confidence: 0.6)
      expect(described_class.should_shadow?('close_pr')).to eq(true)
    end

    it 'returns false when confidence >= 0.8' do
      described_class.record(tool: 'close_pr', lex: 'lex-github:PullRequest:close', confidence: 0.85)
      expect(described_class.should_shadow?('close_pr')).to eq(false)
    end

    it 'returns false when confidence < 0.5' do
      described_class.record(tool: 'close_pr', lex: 'lex-github:PullRequest:close', confidence: 0.3)
      expect(described_class.should_shadow?('close_pr')).to eq(false)
    end
  end

  describe '.lookup' do
    it 'returns nil for unknown tools' do
      expect(described_class.lookup('nonexistent')).to be_nil
    end

    it 'can read existing L2 override confidence when available' do
      stub_const('Legion::Data::Local', Class.new)
      allow(Legion::Data::Local).to receive(:query)
        .with('SELECT * FROM override_confidence WHERE tool = ?', 'from-db')
        .and_return([{ tool: 'from-db', lex: 'lex-db:Tool:run', confidence: 0.9 }])

      expect(described_class.lookup('from-db')[:confidence]).to eq(0.9)
    end
  end

  describe '.all_overrides' do
    it 'returns all stored overrides' do
      described_class.record(tool: 'a', lex: 'lex-a:B:c', confidence: 0.5)
      described_class.record(tool: 'b', lex: 'lex-b:C:d', confidence: 0.9)
      overrides = described_class.all_overrides
      expect(overrides.length).to eq(2)
    end
  end
end
