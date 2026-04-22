# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/resolution'

RSpec.describe Legion::LLM::Router::Resolution do
  subject(:resolution) do
    described_class.new(tier: :local, provider: :ollama, model: 'llama3')
  end

  describe '#initialize and attr_readers' do
    it 'exposes tier as a symbol' do
      expect(resolution.tier).to eq(:local)
    end

    it 'exposes provider as a symbol' do
      expect(resolution.provider).to eq(:ollama)
    end

    it 'exposes model as a string' do
      expect(resolution.model).to eq('llama3')
    end

    it 'defaults rule to nil' do
      expect(resolution.rule).to be_nil
    end

    it 'defaults metadata to empty hash' do
      expect(resolution.metadata).to eq({})
    end

    it 'stores an explicit rule' do
      r = described_class.new(tier: :cloud, provider: :anthropic, model: 'claude-sonnet-4-6', rule: :cost_cap)
      expect(r.rule).to eq(:cost_cap)
    end

    it 'stores explicit metadata' do
      meta = { matched_by: 'schedule', score: 0.9 }
      r = described_class.new(tier: :fleet, provider: :bedrock, model: 'some-model', metadata: meta)
      expect(r.metadata).to eq(meta)
    end

    it 'defaults compress_level to 0' do
      expect(resolution.compress_level).to eq(0)
    end

    it 'stores explicit compress_level' do
      r = described_class.new(tier: :cloud, provider: :bedrock, model: 'claude-sonnet-4-6', compress_level: 2)
      expect(r.compress_level).to eq(2)
    end

    it 'coerces string tier to symbol' do
      r = described_class.new(tier: 'cloud', provider: :anthropic, model: 'claude-sonnet-4-6')
      expect(r.tier).to eq(:cloud)
    end

    it 'coerces string provider to symbol' do
      r = described_class.new(tier: :cloud, provider: 'anthropic', model: 'claude-sonnet-4-6')
      expect(r.provider).to eq(:anthropic)
    end
  end

  describe '#local?' do
    it 'returns true for local tier' do
      expect(resolution.local?).to be true
    end

    it 'returns false for non-local tier' do
      r = described_class.new(tier: :cloud, provider: :anthropic, model: 'claude-sonnet-4-6')
      expect(r.local?).to be false
    end
  end

  describe '#fleet?' do
    it 'returns true for fleet tier' do
      r = described_class.new(tier: :fleet, provider: :bedrock, model: 'some-model')
      expect(r.fleet?).to be true
    end

    it 'returns false for non-fleet tier' do
      expect(resolution.fleet?).to be false
    end
  end

  describe '#cloud?' do
    it 'returns true for cloud tier' do
      r = described_class.new(tier: :cloud, provider: :anthropic, model: 'claude-sonnet-4-6')
      expect(r.cloud?).to be true
    end

    it 'returns false for non-cloud tier' do
      expect(resolution.cloud?).to be false
    end
  end

  describe '#frontier?' do
    it 'returns true for frontier tier' do
      r = described_class.new(tier: :frontier, provider: :anthropic, model: 'claude-sonnet-4-6')
      expect(r.frontier?).to be true
    end

    it 'returns false for non-frontier tier' do
      expect(resolution.frontier?).to be false
    end
  end

  describe '#openai_compat?' do
    it 'returns true for openai_compat tier' do
      r = described_class.new(tier: :openai_compat, provider: :custom_gateway, model: 'gpt-4o')
      expect(r.openai_compat?).to be true
    end

    it 'returns false for non-openai_compat tier' do
      expect(resolution.openai_compat?).to be false
    end
  end

  describe '#external?' do
    it 'returns true for cloud tier' do
      r = described_class.new(tier: :cloud, provider: :bedrock, model: 'claude-sonnet-4-6')
      expect(r.external?).to be true
    end

    it 'returns true for frontier tier' do
      r = described_class.new(tier: :frontier, provider: :anthropic, model: 'claude-sonnet-4-6')
      expect(r.external?).to be true
    end

    it 'returns true for openai_compat tier' do
      r = described_class.new(tier: :openai_compat, provider: :custom_gateway, model: 'gpt-4o')
      expect(r.external?).to be true
    end

    it 'returns false for local tier' do
      expect(resolution.external?).to be false
    end

    it 'returns false for fleet tier' do
      r = described_class.new(tier: :fleet, provider: :ollama, model: 'llama4:70b')
      expect(r.external?).to be false
    end
  end

  describe '#to_h' do
    it 'returns expected hash with defaults' do
      expect(resolution.to_h).to eq(
        tier:           :local,
        provider:       :ollama,
        model:          'llama3',
        rule:           nil,
        metadata:       {},
        compress_level: 0
      )
    end

    it 'includes rule and metadata when set' do
      r = described_class.new(
        tier:     :cloud,
        provider: :anthropic,
        model:    'claude-sonnet-4-6',
        rule:     :default_cloud,
        metadata: { latency_ms: 120 }
      )
      expect(r.to_h).to eq(
        tier:           :cloud,
        provider:       :anthropic,
        model:          'claude-sonnet-4-6',
        rule:           :default_cloud,
        metadata:       { latency_ms: 120 },
        compress_level: 0
      )
    end
  end
end
