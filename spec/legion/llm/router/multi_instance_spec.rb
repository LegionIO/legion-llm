# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'

RSpec.describe 'Router multi-instance provider routing' do
  before do
    Legion::LLM::Router.reset!
    Legion::LLM::Call::Registry.reset!
    allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
    allow(Legion::LLM::Discovery).to receive(:model_available?).and_return(true)
    allow(Legion::LLM::Discovery).to receive(:model_size).and_return(nil)
    allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(65_536)
  end

  def configure_multi_instance_rules
    rules = [
      {
        name:     'vllm-apollo-chat',
        when:     { operation: 'chat' },
        then:     {
          tier: 'direct', provider: 'vllm', instance: 'apollo',
          model: 'legion-code-27b-v1', effort: 'moderate',
          model_capabilities: %i[completion streaming tools thinking]
        },
        priority: 100
      },
      {
        name:     'vllm-default-chat',
        when:     { operation: 'chat' },
        then:     {
          tier: 'direct', provider: 'vllm', instance: 'default',
          model: 'gemma-4-12b-it', effort: 'low',
          model_capabilities: %i[completion streaming]
        },
        priority: 80
      }
    ]

    Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                      routing: {
                                        enabled:        true,
                                        rules:          rules,
                                        default_intent: { privacy: 'normal', effort: 'moderate', operation: 'chat' }
                                      }
                                    ))
    Legion::LLM::Router.populate_auto_rules({})
  end

  describe 'same provider, different instances, different capabilities' do
    before { configure_multi_instance_rules }

    it 'routes tools request to the capable instance (apollo), not the incapable one (default)' do
      result = Legion::LLM::Router.resolve(
        intent: { operation: :chat, effort: :moderate, required_capabilities: [:tools] }
      )

      expect(result).not_to be_nil
      expect(result.provider).to eq(:vllm)
      expect(result.instance).to eq(:apollo)
      expect(result.model).to eq('legion-code-27b-v1')
    end

    it 'routes streaming-only request to either instance (both support streaming)' do
      result = Legion::LLM::Router.resolve(
        intent: { operation: :chat, effort: :low, required_capabilities: [:streaming] }
      )

      expect(result).not_to be_nil
      expect(result.provider).to eq(:vllm)
    end
  end

  describe 'stale default on one instance does not poison another' do
    before do
      configure_multi_instance_rules

      Legion::LLM::Call::Registry.register(:vllm, Module.new, instance: :apollo,
                                                              metadata: { default_model: 'legion-code-27b-v1', tier: :direct })
      Legion::LLM::Call::Registry.register(:vllm, Module.new, instance: :default,
                                                              metadata: { default_model: 'gemma-4-12b-it', tier: :direct })

      allow(Legion::LLM::Discovery).to receive(:cached_discovered_models).and_return(
        [
          { schema_version: 2, provider: :vllm, instance: :apollo, model: 'legion-code-27b-v1',
            capabilities: %i[completion streaming tools thinking], context_length: 262_144 }
        ]
      )
      Legion::LLM::Discovery.record_discovery_status(provider: :vllm, instance: :apollo, status: :ok)
      Legion::LLM::Discovery.record_discovery_status(provider: :vllm, instance: :default, status: :ok)
    end

    it 'rejects stale model on :default instance without affecting :apollo' do
      apollo_resolution = Legion::LLM::Router::Resolution.new(
        tier: :direct, provider: :vllm, instance: :apollo, model: 'legion-code-27b-v1', metadata: {}
      )
      default_resolution = Legion::LLM::Router::Resolution.new(
        tier: :direct, provider: :vllm, instance: :default, model: 'gemma-4-12b-it', metadata: {}
      )

      expect(Legion::LLM::Router::Availability.rejection_reason(
               apollo_resolution, estimated_tokens: nil, required_capabilities: []
             )).to be_nil

      reason = Legion::LLM::Router::Availability.rejection_reason(
        default_resolution, estimated_tokens: nil, required_capabilities: []
      )
      expect(%i[model_not_offered provider_instance_has_no_models]).to include(reason)
    end
  end

  describe 'provider-only hint resolves to real registered instance' do
    before do
      configure_multi_instance_rules
      Legion::LLM::Call::Registry.register(:vllm, Module.new, instance: :apollo,
                                                              metadata: { default_model: 'legion-code-27b-v1', tier: :direct })
    end

    it 'resolves to the registered instance, not implicit :default' do
      result = Legion::LLM::Router.resolve(provider: :vllm)
      expect(result).not_to be_nil
      expect(result.instance).to eq(:apollo)
    end
  end

  describe 'chain_from_intent preserves different instances for same provider/model' do
    before do
      Legion::LLM::Router.reset!
      Legion::LLM::Call::Registry.reset!
      Legion::LLM::Discovery.reset!
      allow(Legion::LLM::Discovery).to receive(:model_available?).and_return(true)
      allow(Legion::LLM::Discovery::MemoryGate).to receive(:allow?).and_return(true)
      rules = [
        {
          name:     'vllm-apollo-chat',
          when:     { operation: 'chat' },
          then:     {
            tier: 'direct', provider: 'vllm', instance: 'apollo',
            model: 'qwen3-27b', effort: 'moderate',
            model_capabilities: %i[completion streaming tools]
          },
          priority: 100
        },
        {
          name:     'vllm-local-chat',
          when:     { operation: 'chat' },
          then:     {
            tier: 'local', provider: 'vllm', instance: 'local',
            model: 'qwen3-27b', effort: 'low',
            model_capabilities: %i[completion streaming]
          },
          priority: 80
        }
      ]
      Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                        routing: {
                                          enabled: true, rules: rules,
                                          default_intent: { effort: 'moderate', operation: 'chat' }
                                        }
                                      ))
      Legion::LLM::Router.populate_auto_rules({})
    end

    it 'does not collapse same-model different-instance resolutions' do
      chain = Legion::LLM::Router.resolve_chain(intent: { operation: :chat, effort: :moderate })
      vllm_resolutions = chain.to_a.select { |r| r.provider == :vllm }
      instances = vllm_resolutions.map(&:instance)
      expect(instances).to contain_exactly(:apollo, :local)
    end
  end

  describe 'chain_from_defaults carries registered instance' do
    before do
      Legion::LLM::Call::Registry.register(:vllm, Module.new, instance: :apollo,
                                                              metadata: { default_model: 'legion-code-27b-v1', tier: :direct })
      Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                        default_provider: :vllm,
                                        routing:          { enabled: false, rules: [] }
                                      ))
    end

    it 'primary resolution carries instance: :apollo, not nil or :default' do
      chain = Legion::LLM::Router.resolve_chain(intent: { operation: :chat })
      primary = chain.primary
      expect(primary.provider).to eq(:vllm)
      expect(primary.instance).to eq(:apollo)
      expect(primary.model).to eq('legion-code-27b-v1')
    end
  end

  describe 'enabled_provider_chain includes all instances' do
    before do
      Legion::LLM::Call::Registry.register(:vllm, Module.new, instance: :apollo,
                                                              metadata: { default_model: 'legion-code-27b-v1', tier: :direct })
      Legion::LLM::Call::Registry.register(:vllm, Module.new, instance: :local,
                                                              metadata: { default_model: 'qwen3:7b', tier: :local })
    end

    it 'returns resolutions for all registered instances, not just the first' do
      chain = Legion::LLM::Router.send(:enabled_provider_chain)

      vllm_instances = chain.select { |r| r.provider == :vllm }.map(&:instance)
      expect(vllm_instances).to contain_exactly(:apollo, :local)
    end

    it 'never returns instance=:default when only :apollo is registered' do
      Legion::LLM::Call::Registry.reset!
      Legion::LLM::Call::Registry.register(:vllm, Module.new, instance: :apollo,
                                                              metadata: { default_model: 'legion-code-27b-v1', tier: :direct })

      chain = Legion::LLM::Router.send(:enabled_provider_chain)

      vllm_resolutions = chain.select { |r| r.provider == :vllm }
      expect(vllm_resolutions.none? { |r| r.instance == :default }).to be(true)
      expect(vllm_resolutions.first.instance).to eq(:apollo)
    end
  end

  # Regression: an explicit provider hint must exhaust ALL of that provider's
  # registered instances (e.g. two accounts of the same provider) before the chain
  # crosses to a different provider. Previously only the first instance was
  # prepended, so a failing primary instance failed straight over to another
  # provider, skipping the provider's second instance entirely.
  describe 'explicit provider hint fails over across all its instances first' do
    before do
      Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                        routing: { enabled: true, rules: [], default_intent: { operation: 'chat' } }
                                      ))
      Legion::LLM::Router.populate_auto_rules({})
      Legion::LLM::Call::Registry.register(:anthropic, Module.new, instance: :primary,
                                                                   metadata: { default_model: 'claude-haiku-4-5-20251001', tier: :frontier })
      Legion::LLM::Call::Registry.register(:anthropic, Module.new, instance: :secondary,
                                                                   metadata: { default_model: 'claude-haiku-4-5-20251001', tier: :frontier })
      Legion::LLM::Call::Registry.register(:vllm, Module.new, instance: :apollo,
                                                              metadata: { default_model: 'gemma-4-12b-it', tier: :direct })
      allow(Legion::LLM::Router::Availability).to receive(:filter_resolutions) { |resolutions, **| resolutions }
    end

    it 'includes both anthropic instances ahead of any other provider' do
      chain = Legion::LLM::Router.resolve_chain(provider: :anthropic, intent: { operation: :chat, effort: :moderate })
      providers_in_order = chain.to_a.map(&:provider)
      anthropic_instances = chain.to_a.select { |r| r.provider == :anthropic }.map(&:instance)

      expect(anthropic_instances).to contain_exactly(:primary, :secondary)
      # No non-anthropic provider appears before both anthropic instances are tried.
      first_non_anthropic = providers_in_order.index { |p| p != :anthropic }
      expect(first_non_anthropic).to be >= 2 if first_non_anthropic
    end
  end
end
