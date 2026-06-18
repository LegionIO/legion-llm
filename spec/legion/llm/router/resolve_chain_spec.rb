# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'
require 'legion/llm/router/escalation/chain'

RSpec.describe 'Legion::LLM::Router.resolve_chain' do
  before do
    Legion::LLM::Router.reset!
    # Reset the registry so a provider registered by one example (e.g. the
    # routing-disabled multi-provider case) does not leak into another under
    # random spec order — provider registration now influences chain primaries.
    Legion::LLM::Call::Registry.reset!
    Legion::Settings.set_prop(:llm, {
                                default_model:    'claude-sonnet-4-6',
                                default_provider: :bedrock,
                                providers:        {
                                  ollama:  { enabled: true, default_model: 'llama3' },
                                  bedrock: { enabled: true, default_model: 'us.anthropic.claude-sonnet-4-6-v1' }
                                },
                                discovery:        { enabled: false },
                                routing:          {
                                  enabled:        true,
                                  default_intent: { privacy: 'normal', effort: 'moderate', operation: 'chat', cost: 'normal' },
                                  escalation:     { enabled: true, max_attempts: 3, quality_threshold: 50 },
                                  rules:          rules
                                }
                              })
    Legion::LLM::Router.populate_auto_rules({})
  end

  context 'with explicit fallback chain in rules' do
    let(:rules) do
      [
        { name: 'local-low', when: { effort: 'low' },
          then: { tier: :local, provider: :ollama, model: 'llama3' },
          priority: 10, fallback: { tier: :cloud, provider: :bedrock, model: 'us.anthropic.claude-sonnet-4-6-v1' } },
        { name: 'cloud-moderate', when: { effort: 'moderate' },
          then: { tier: :cloud, provider: :bedrock, model: 'us.anthropic.claude-sonnet-4-6-v1' },
          priority: 5 }
      ]
    end

    it 'follows fallback fields to build chain' do
      chain = Legion::LLM::Router.resolve_chain(intent: { effort: :low })
      expect(chain).to be_a(Legion::LLM::Router::EscalationChain)
      expect(chain.size).to be >= 2
      expect(chain.primary.model).to eq('llama3')
    end
  end

  context 'with no fallback fields' do
    let(:rules) do
      [
        { name: 'local-low', when: { effort: 'low' },
          then: { tier: :local, provider: :ollama, model: 'llama3' },
          priority: 10 },
        { name: 'cloud-low', when: { effort: 'low' },
          then: { tier: :cloud, provider: :bedrock, model: 'us.anthropic.claude-sonnet-4-6-v1' },
          priority: 5 }
      ]
    end

    it 'auto-generates tier-first chain from candidates' do
      chain = Legion::LLM::Router.resolve_chain(intent: { effort: :low })
      expect(chain.size).to be >= 2
      expect(chain.primary.tier).to eq(:local)
    end
  end

  context 'with provider preference and no matching provider rule' do
    let(:rules) do
      [
        { name: 'openai-tools', when: { operation: 'chat', required_capabilities: [:tools] },
          then: { tier: :frontier, provider: :openai, model: 'gpt-5.5' },
          priority: 100 },
        { name: 'vllm-tools', when: { operation: 'chat', required_capabilities: [:tools] },
          then: { tier: :direct, provider: :vllm, instance: :h200, model: 'gemma-4-31b-it' },
          priority: 80 }
      ]
    end

    it 'falls back to the normal chain when no candidate matches the provider preference' do
      chain = Legion::LLM::Router.resolve_chain(
        intent:   { operation: :chat, required_capabilities: [:tools] },
        provider: :bedrock,
        model:    'anthropic.claude-sonnet-4'
      )

      expect(chain.primary.provider).to eq(:bedrock)
      expect(chain.primary.model).to eq('claude-sonnet-4-6')
    end
  end

  context 'with max_escalations parameter' do
    let(:rules) do
      [
        { name: 'r1', when: { effort: 'low' }, then: { tier: :local, provider: :ollama, model: 'llama3' }, priority: 10 },
        { name: 'r2', when: { effort: 'low' }, then: { tier: :cloud, provider: :bedrock, model: 'sonnet' }, priority: 5 },
        { name: 'r3', when: { effort: 'low' }, then: { tier: :cloud, provider: :bedrock, model: 'opus' }, priority: 1 }
      ]
    end

    it 'respects max_escalations parameter' do
      chain = Legion::LLM::Router.resolve_chain(intent: { effort: :low }, max_escalations: 2)
      expect(chain.max_attempts).to eq(2)
      count = 0
      chain.each { count += 1 }
      expect(count).to be <= 2
    end
  end

  context 'when routing is disabled (no rules)' do
    let(:rules) { [] }

    before { Legion::Settings[:llm][:routing][:enabled] = false }

    it 'honours explicit default provider/model before auto-enabled providers' do
      chain = Legion::LLM::Router.resolve_chain(intent: { effort: :low })
      expect(chain.size).to eq(1)
      expect(chain.primary.provider).to eq(:bedrock)
      expect(chain.primary.model).to eq('claude-sonnet-4-6')
    end

    it 'can suppress settings default fallback for strict auto routing' do
      chain = Legion::LLM::Router.resolve_chain(
        intent:                 { effort: :low },
        allow_default_fallback: false
      )

      expect(chain).to be_empty
    end

    it 'returns a multi-provider chain from registry-registered providers' do
      Legion::Settings.set_prop(:llm, {
                                  'discovery' => { 'enabled' => false },
                                  'routing'   => { 'enabled' => false, 'rules' => [] }
                                })

      Legion::LLM::Call::Registry.register(:ollama, Module.new, metadata: { default_model: 'llama3' })
      Legion::LLM::Call::Registry.register(:bedrock, Module.new, metadata: { default_model: 'us.anthropic.claude-sonnet-4-6-v1' })

      chain = Legion::LLM::Router.resolve_chain(intent: { effort: :low })

      expect(chain.map(&:provider)).to include(:bedrock, :ollama)
    end

    it 'honours explicit provider with a single-resolution chain' do
      chain = Legion::LLM::Router.resolve_chain(provider: :bedrock, max_escalations: 3)
      expect(chain.size).to eq(1)
      expect(chain.primary.provider).to eq(:bedrock)
    end
  end

  # SSOT gate: escalation fallbacks must never manufacture a (provider, model)
  # the live catalog doesn't offer — that produced a dead candidate availability
  # rejected (model_not_offered) on every request, spamming resolution_unavailable.
  describe '.fallback_model_offered?' do
    let(:rules) { [] }

    it 'is false when the catalog has offerings but not the model' do
      allow(Legion::LLM::Inventory).to receive(:offerings).and_call_original
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :bedrock))
                                                          .and_return([{ provider_family: 'bedrock', model: 'us.anthropic.claude-3-haiku' }])
      expect(Legion::LLM::Router.fallback_model_offered?(:bedrock, 'us.anthropic.claude-sonnet-4')).to be(false)
    end

    it 'is true when the model is offered' do
      allow(Legion::LLM::Inventory).to receive(:offerings).and_call_original
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :bedrock))
                                                          .and_return([{ provider_family: 'bedrock', model: 'us.anthropic.claude-sonnet-4' }])
      expect(Legion::LLM::Router.fallback_model_offered?(:bedrock, 'us.anthropic.claude-sonnet-4')).to be(true)
    end

    it 'stays permissive on an empty catalog so cold boot does not over-prune' do
      allow(Legion::LLM::Inventory).to receive(:offerings).and_call_original
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :bedrock)).and_return([])
      expect(Legion::LLM::Router.fallback_model_offered?(:bedrock, 'anything')).to be(true)
    end
  end
end
