# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/ollama'
require 'legion/llm/discovery/system'

RSpec.describe 'Router discovery integration' do
  let(:rules_with_local) do
    [
      {
        name:            'local-small',
        when:            { capability: 'basic' },
        then:            { tier: 'local', provider: 'ollama', model: 'llama3.1:8b' },
        priority:        80,
        cost_multiplier: 0.1
      },
      {
        name:            'cloud-fallback',
        when:            { capability: 'basic' },
        then:            { tier: 'cloud', provider: 'bedrock', model: 'claude-sonnet-4-6' },
        priority:        20,
        cost_multiplier: 1.0
      }
    ]
  end

  before do
    Legion::LLM::Router.reset!
    Legion::LLM::Discovery::Ollama.reset!
    Legion::LLM::Discovery::System.reset!
    allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
  end

  def configure_routing(rules:)
    Legion::Settings[:llm] = Legion::Settings[:llm].merge(
      routing:   {
        enabled:        true,
        rules:          rules,
        default_intent: { privacy: 'normal', capability: 'basic' }
      },
      discovery: { enabled: true, refresh_seconds: 60, memory_floor_mb: 2048 }
    )
  end

  describe 'when Ollama model is not pulled' do
    before do
      configure_routing(rules: rules_with_local)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).with('llama3.1:8b').and_return(false)
      allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(32_000)
    end

    it 'skips the local rule and falls through to cloud' do
      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.rule).to eq('cloud-fallback')
      expect(result.tier).to eq(:cloud)
    end
  end

  describe 'when Ollama model is pulled and fits in memory' do
    before do
      configure_routing(rules: rules_with_local)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).with('llama3.1:8b').and_return(true)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).with('llama3.1:8b').and_return(4_700_000_000)
      allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(32_000)
    end

    it 'selects the local rule' do
      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.rule).to eq('local-small')
      expect(result.tier).to eq(:local)
    end
  end

  describe 'when model is pulled but does not fit in memory' do
    before do
      configure_routing(rules: rules_with_local)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).with('llama3.1:8b').and_return(true)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).with('llama3.1:8b').and_return(4_700_000_000)
      # 5000 MB available - 2048 MB floor = 2952 MB usable, model needs ~4482 MB
      allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(5_000)
    end

    it 'skips the local rule (insufficient memory after floor)' do
      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.rule).to eq('cloud-fallback')
    end
  end

  describe 'when discovery is disabled' do
    before do
      Legion::Settings[:llm] = Legion::Settings[:llm].merge(
        routing:   {
          enabled:        true,
          rules:          rules_with_local,
          default_intent: { privacy: 'normal', capability: 'basic' }
        },
        discovery: { enabled: false }
      )
    end

    it 'does not filter by discovery — local rule passes through' do
      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.rule).to eq('local-small')
    end
  end

  describe 'when system memory is nil (unknown platform)' do
    before do
      configure_routing(rules: rules_with_local)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?).with('llama3.1:8b').and_return(true)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_size).with('llama3.1:8b').and_return(4_700_000_000)
      allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(nil)
    end

    it 'bypasses memory check (permissive) and selects local rule' do
      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.rule).to eq('local-small')
    end
  end

  describe 'non-Ollama rules are unaffected' do
    let(:cloud_only_rules) do
      [
        {
          name:            'cloud-reasoning',
          when:            { capability: 'reasoning' },
          then:            { tier: 'cloud', provider: 'bedrock', model: 'claude-sonnet-4-6' },
          priority:        50,
          cost_multiplier: 1.0
        }
      ]
    end

    before { configure_routing(rules: cloud_only_rules) }

    it 'does not check discovery for cloud rules' do
      expect(Legion::LLM::Discovery::Ollama).not_to receive(:model_available?)
      Legion::LLM::Router.resolve(intent: { capability: 'reasoning' })
    end
  end
end
