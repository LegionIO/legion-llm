# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'
require 'legion/llm/router/escalation/chain'

RSpec.describe 'Legion::LLM::Router.resolve_chain' do
  before do
    Legion::LLM::Router.reset!
    Legion::Settings[:llm] = {
      default_model:    'claude-sonnet-4-6',
      default_provider: :bedrock,
      providers:        {
        ollama:  { enabled: true, default_model: 'llama3' },
        bedrock: { enabled: true, default_model: 'us.anthropic.claude-sonnet-4-6-v1' }
      },
      discovery:        { enabled: false },
      routing:          {
        enabled:        true,
        default_intent: { privacy: 'normal', capability: 'moderate', cost: 'normal' },
        escalation:     { enabled: true, max_attempts: 3, quality_threshold: 50 },
        rules:          rules
      }
    }
  end

  context 'with explicit fallback chain in rules' do
    let(:rules) do
      [
        { name: 'local-basic', when: { capability: 'basic' },
          then: { tier: :local, provider: :ollama, model: 'llama3' },
          priority: 10, fallback: { tier: :cloud, provider: :bedrock, model: 'us.anthropic.claude-sonnet-4-6-v1' } },
        { name: 'cloud-moderate', when: { capability: 'moderate' },
          then: { tier: :cloud, provider: :bedrock, model: 'us.anthropic.claude-sonnet-4-6-v1' },
          priority: 5 }
      ]
    end

    it 'follows fallback fields to build chain' do
      chain = Legion::LLM::Router.resolve_chain(intent: { capability: :basic })
      expect(chain).to be_a(Legion::LLM::Router::EscalationChain)
      expect(chain.size).to be >= 2
      expect(chain.primary.model).to eq('llama3')
    end
  end

  context 'with no fallback fields' do
    let(:rules) do
      [
        { name: 'local-basic', when: { capability: 'basic' },
          then: { tier: :local, provider: :ollama, model: 'llama3' },
          priority: 10 },
        { name: 'cloud-basic', when: { capability: 'basic' },
          then: { tier: :cloud, provider: :bedrock, model: 'us.anthropic.claude-sonnet-4-6-v1' },
          priority: 5 }
      ]
    end

    it 'auto-generates tier-first chain from candidates' do
      chain = Legion::LLM::Router.resolve_chain(intent: { capability: :basic })
      expect(chain.size).to be >= 2
      expect(chain.primary.tier).to eq(:local)
    end
  end

  context 'with max_escalations parameter' do
    let(:rules) do
      [
        { name: 'r1', when: { capability: 'basic' }, then: { tier: :local, provider: :ollama, model: 'llama3' }, priority: 10 },
        { name: 'r2', when: { capability: 'basic' }, then: { tier: :cloud, provider: :bedrock, model: 'sonnet' }, priority: 5 },
        { name: 'r3', when: { capability: 'basic' }, then: { tier: :cloud, provider: :bedrock, model: 'opus' }, priority: 1 }
      ]
    end

    it 'respects max_escalations parameter' do
      chain = Legion::LLM::Router.resolve_chain(intent: { capability: :basic }, max_escalations: 2)
      expect(chain.max_attempts).to eq(2)
      count = 0
      chain.each { count += 1 }
      expect(count).to be <= 2
    end
  end

  context 'when routing is disabled (no rules)' do
    let(:rules) { [] }

    before { Legion::Settings[:llm][:routing][:enabled] = false }

    it 'returns a multi-provider chain from all enabled providers' do
      chain = Legion::LLM::Router.resolve_chain(intent: { capability: :basic })
      expect(chain.size).to be >= 1
      providers = chain.map(&:provider)
      expect(providers).to include(:bedrock).or include(:ollama)
    end

    it 'honours explicit provider with a single-resolution chain' do
      chain = Legion::LLM::Router.resolve_chain(provider: :bedrock, max_escalations: 3)
      expect(chain.size).to eq(1)
      expect(chain.primary.provider).to eq(:bedrock)
    end
  end
end
