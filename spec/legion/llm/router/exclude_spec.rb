# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Router do
  let(:routing_rules) do
    [
      {
        name:     'cloud-anthropic',
        when:     { capability: 'reasoning' },
        then:     { tier: 'cloud', provider: 'anthropic', model: 'claude-opus-4-6' },
        priority: 10
      },
      {
        name:     'cloud-openai',
        when:     { capability: 'reasoning' },
        then:     { tier: 'cloud', provider: 'openai', model: 'gpt-4o' },
        priority: 5
      },
      {
        name:     'local-ollama',
        when:     { capability: 'moderate' },
        then:     { tier: 'local', provider: 'ollama', model: 'llama3' },
        priority: 8
      }
    ]
  end

  def configure_routing(rules: routing_rules)
    Legion::Settings[:llm] = Legion::Settings[:llm].merge(
      routing: {
        enabled:        true,
        rules:          rules,
        default_intent: { privacy: 'normal', capability: 'moderate', cost: 'normal' }
      }
    )
  end

  before do
    described_class.reset!
    configure_routing
    allow(described_class).to receive(:tier_available?).and_return(true)
    allow(described_class).to receive(:discovery_enabled?).and_return(false)
  end

  after { described_class.reset! }

  describe '.resolve with exclude:' do
    it 'accepts exclude: parameter without error' do
      expect do
        described_class.resolve(intent: { capability: :reasoning }, exclude: {})
      end.not_to raise_error
    end

    it 'excludes a specific provider when exclude: { provider: } is given' do
      resolution = described_class.resolve(
        intent:  { capability: :reasoning },
        exclude: { provider: :anthropic }
      )
      expect(resolution).not_to be_nil
      expect(resolution.provider).not_to eq(:anthropic)
      expect(resolution.provider).to eq(:openai)
    end

    it 'excludes a specific model when exclude: { model: } is given' do
      resolution = described_class.resolve(
        intent:  { capability: :reasoning },
        exclude: { model: 'claude-opus-4-6' }
      )
      expect(resolution).not_to be_nil
      expect(resolution.model).not_to eq('claude-opus-4-6')
    end

    it 'returns nil when all candidates are excluded' do
      resolution = described_class.resolve(
        intent:  { capability: :reasoning },
        exclude: { provider: :anthropic, model: 'gpt-4o' }
      )
      expect(resolution).to be_nil
    end

    it 'does not exclude when exclude: is empty {}' do
      resolution = described_class.resolve(
        intent:  { capability: :reasoning },
        exclude: {}
      )
      expect(resolution).not_to be_nil
    end
  end

  describe '.resolve_chain with exclude:' do
    it 'accepts exclude: parameter' do
      expect do
        described_class.resolve_chain(intent: { capability: :reasoning }, exclude: {})
      end.not_to raise_error
    end

    it 'excludes specified provider from the chain' do
      chain = described_class.resolve_chain(
        intent:  { capability: :reasoning },
        exclude: { provider: :anthropic }
      )
      providers = chain.to_a.map(&:provider)
      expect(providers).not_to include(:anthropic)
      expect(providers).to include(:openai)
    end
  end
end
