# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'
require 'legion/llm/router/availability'

RSpec.describe 'Router determinism and regression coverage' do
  before do
    Legion::LLM::Router.reset!
    allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
    allow(Legion::LLM::Discovery).to receive(:model_available?).and_return(true)
    allow(Legion::LLM::Discovery).to receive(:model_size).and_return(nil)
    allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(65_536)
  end

  def configure_with_rules(rules, default_intent: { privacy: 'normal', effort: 'moderate', operation: 'chat' })
    Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                      routing: {
                                        enabled:        true,
                                        rules:          rules,
                                        default_intent: default_intent
                                      }
                                    ))
    Legion::LLM::Router.populate_auto_rules({})
  end

  # ─── Regression (C15): stale default_intent[:capability] must NOT brick routing ──
  # The :capability dimension was renamed to :operation + :effort. On-disk config (and
  # caller intent) predating the rename must be tolerated — the legacy key is ignored,
  # not raised on. Previously this raised ArgumentError on every resolve, bricking any
  # install whose default_intent still carried the old shipped { capability: 'moderate' }.

  describe 'stale settings with capability: key' do
    before do
      Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                        default_provider: :vllm,
                                        default_model:    'qwen3.6-27b',
                                        routing:          {
                                          enabled:        true,
                                          rules:          [],
                                          default_intent: { privacy: 'normal', capability: 'moderate' }
                                        }
                                      ))
      Legion::LLM::Router.populate_auto_rules({})
    end

    it 'does not raise from Router.resolve when default_intent contains capability:' do
      expect { Legion::LLM::Router.resolve(intent: { effort: :moderate }) }.not_to raise_error
    end

    it 'does not raise from Router.resolve_chain when default_intent contains capability:' do
      expect { Legion::LLM::Router.resolve_chain(intent: { effort: :moderate }) }.not_to raise_error
    end

    it 'does not raise when a caller passes a legacy capability: intent directly' do
      expect { Legion::LLM::Router.resolve(intent: { capability: 'moderate' }) }.not_to raise_error
    end
  end

  # ─── Regression: last-resort fallback is filtered through live availability ──

  describe 'last-resort fallback availability filtering' do
    before do
      configure_with_rules([])
      Legion::Settings[:llm][:default_provider] = :vllm
      Legion::Settings[:llm][:default_model] = 'qwen3.6-27b'

      # Only legion-code-27b-v1 is in the live catalog — qwen3.6-27b is not offered.
      Legion::LLM::Inventory.write_lane(lane: {
                                          id:              'direct:vllm:default:inference:legion-code-27b-v1',
                                          tier:            :direct,
                                          provider_family: :vllm,
                                          instance_id:     :default,
                                          model:           'legion-code-27b-v1',
                                          type:            :inference,
                                          capabilities:    %i[completion streaming tools thinking],
                                          limits:          { context_window: 262_144 },
                                          enabled:         true,
                                          cost:            {}
                                        })
      Legion::LLM::Discovery.record_discovery_status(provider: :vllm, instance: nil, status: :ok)
    end

    it 'rejects stale last-resort model when live catalog has contradicting data' do
      chain = Legion::LLM::Router.resolve_chain(
        intent:                 { operation: :chat, effort: :moderate },
        allow_default_fallback: true
      )

      models = chain.map(&:model)
      expect(models).not_to include('qwen3.6-27b')
    end
  end

  # ─── Deterministic routing fingerprint ───────────────────────────────────────

  describe 'deterministic routing' do
    before do
      rules = [
        {
          name:     'chat-tools-vllm',
          when:     { operation: 'chat' },
          then:     {
            tier: 'direct', provider: 'vllm', instance: 'apollo',
            model: 'legion-code-27b-v1', effort: 'moderate',
            model_capabilities: %i[completion streaming tools thinking]
          },
          priority: 100
        }
      ]
      configure_with_rules(rules)
    end

    it 'resolves identically across repeated calls with the same intent' do
      intent = {
        privacy:               :normal,
        effort:                :moderate,
        operation:             :chat,
        cost:                  :normal,
        required_capabilities: [:tools]
      }

      fingerprints = 3.times.map do
        resolution = Legion::LLM::Router.resolve(intent: intent)
        [resolution.provider, resolution.instance, resolution.model]
      end

      expect(fingerprints.uniq.size).to eq(1)
    end
  end

  # ─── Hard capability filtering: tools, streaming, thinking ───────────────────

  describe 'hard capability filtering' do
    before do
      rules = [
        {
          name:     'chat-no-tools',
          when:     { operation: 'chat' },
          then:     {
            tier: 'local', provider: 'ollama', model: 'tiny-model',
            model_capabilities: %i[completion streaming]
          },
          priority: 200
        },
        {
          name:     'chat-with-tools',
          when:     { operation: 'chat' },
          then:     {
            tier: 'direct', provider: 'vllm', instance: 'apollo',
            model: 'legion-code-27b-v1',
            model_capabilities: %i[completion streaming tools]
          },
          priority: 100
        },
        {
          name:     'stream-with-tools',
          when:     { operation: 'stream' },
          then:     {
            tier: 'direct', provider: 'vllm', instance: 'apollo',
            model: 'legion-code-27b-v1',
            model_capabilities: %i[completion streaming tools]
          },
          priority: 100
        },
        {
          name:     'chat-with-thinking',
          when:     { operation: 'chat' },
          then:     {
            tier: 'cloud', provider: 'bedrock', model: 'claude-sonnet-4-6',
            model_capabilities: %i[completion streaming tools thinking]
          },
          priority: 50
        }
      ]
      configure_with_rules(rules)
    end

    it 'selects tool-capable route when tools are required, not the higher-priority non-tool route' do
      result = Legion::LLM::Router.resolve(
        intent: { operation: :chat, effort: :moderate, required_capabilities: [:tools] }
      )

      expect(result).not_to be_nil
      expect(result.model).to eq('legion-code-27b-v1')
      expect(result.provider).to eq(:vllm)
    end

    it 'selects streaming-capable route when streaming is required' do
      result = Legion::LLM::Router.resolve(
        intent: { operation: :stream, effort: :moderate, required_capabilities: [:streaming] }
      )

      expect(result).not_to be_nil
      expect(result.metadata[:model_capabilities]).to include(:streaming)
    end

    it 'selects thinking-capable route when thinking is required' do
      result = Legion::LLM::Router.resolve(
        intent: { operation: :chat, effort: :moderate, required_capabilities: [:thinking] }
      )

      expect(result).not_to be_nil
      expect(result.metadata[:model_capabilities]).to include(:thinking)
    end
  end

  # ─── Stale vLLM model rejected by live catalog ──────────────────────────────

  describe 'live catalog enforcement' do
    let(:vllm_apollo_offering) do
      {
        model:           'legion-code-27b-v1',
        provider_family: 'vllm',
        instance_id:     'apollo',
        capabilities:    %w[completion streaming tools thinking],
        limits:          { context_window: 262_144 }
      }
    end

    before do
      allow(Legion::LLM::Discovery).to receive(:cached_discovered_models).and_return(
        [
          {
            provider:       :vllm,
            instance:       :apollo,
            model:          'legion-code-27b-v1',
            capabilities:   %i[completion streaming tools thinking],
            context_length: 262_144
          }
        ]
      )
      Legion::LLM::Discovery.record_discovery_status(provider: :vllm, instance: :apollo, status: :ok)
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :vllm)).and_return([vllm_apollo_offering])
    end

    it 'rejects a stale model not present in live offerings' do
      resolution = Legion::LLM::Router::Resolution.new(
        tier:     :direct,
        provider: :vllm,
        instance: :apollo,
        model:    'qwen3.6-27b',
        metadata: { model_capabilities: %i[completion streaming tools] }
      )

      reason = Legion::LLM::Router::Availability.rejection_reason(
        resolution,
        estimated_tokens:      nil,
        required_capabilities: [:tools]
      )

      expect(reason).to eq(:model_not_offered)
    end

    it 'accepts a model present in live offerings' do
      resolution = Legion::LLM::Router::Resolution.new(
        tier:     :direct,
        provider: :vllm,
        instance: :apollo,
        model:    'legion-code-27b-v1',
        metadata: {}
      )

      reason = Legion::LLM::Router::Availability.rejection_reason(
        resolution,
        estimated_tokens:      nil,
        required_capabilities: [:tools]
      )

      expect(reason).to be_nil
    end

    it 'rejects a live model missing required capabilities' do
      no_tools_offering = vllm_apollo_offering.merge(capabilities: %w[completion streaming])
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :vllm)).and_return([no_tools_offering])

      resolution = Legion::LLM::Router::Resolution.new(
        tier:     :direct,
        provider: :vllm,
        instance: :apollo,
        model:    'legion-code-27b-v1',
        metadata: {}
      )

      reason = Legion::LLM::Router::Availability.rejection_reason(
        resolution,
        estimated_tokens:      nil,
        required_capabilities: [:tools]
      )

      expect(reason).to eq(:missing_capability)
    end

    it 'is permissive when Inventory is unavailable (cold boot fallback)' do
      allow(Legion::LLM::Inventory).to receive(:offerings).and_raise(StandardError, 'not ready')

      resolution = Legion::LLM::Router::Resolution.new(
        tier:     :direct,
        provider: :vllm,
        instance: :apollo,
        model:    'any-model-whatever',
        metadata: {}
      )

      reason = Legion::LLM::Router::Availability.rejection_reason(
        resolution,
        estimated_tokens:      nil,
        required_capabilities: []
      )

      expect(reason).to be_nil
    end

    it 'rejects when Inventory returns no models for a provider' do
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :vllm)).and_return([])

      resolution = Legion::LLM::Router::Resolution.new(
        tier:     :direct,
        provider: :vllm,
        instance: :apollo,
        model:    'legion-code-27b-v1',
        metadata: {}
      )

      reason = Legion::LLM::Router::Availability.rejection_reason(
        resolution,
        estimated_tokens:      nil,
        required_capabilities: []
      )

      expect(reason).to eq(:provider_instance_has_no_models)
    end
  end

  # ─── resolve_chain returns empty when no confirmed candidate has :thinking ──

  describe 'resolve_chain with unmet thinking requirement' do
    before do
      rules = [
        {
          name:     'chat-no-thinking',
          when:     { operation: 'chat' },
          then:     {
            tier: 'direct', provider: 'vllm', instance: 'apollo',
            model: 'legion-code-27b-v1',
            model_capabilities: %i[completion streaming tools]
          },
          priority: 100
        }
      ]
      configure_with_rules(rules)

      allow(Legion::LLM::Discovery).to receive(:cached_discovered_models).and_return(
        [
          {
            provider:       :vllm,
            instance:       :apollo,
            model:          'legion-code-27b-v1',
            capabilities:   %i[completion streaming tools],
            context_length: 262_144
          }
        ]
      )
      Legion::LLM::Discovery.record_discovery_status(provider: :vllm, instance: :apollo, status: :ok)
    end

    it 'returns empty chain when no confirmed candidate has :thinking' do
      chain = Legion::LLM::Router.resolve_chain(
        intent:                 { operation: :chat, effort: :moderate, required_capabilities: [:thinking] },
        allow_default_fallback: false
      )

      expect(chain).to be_empty
    end
  end

  # ─── Regression: explicit provider hint honored on EVERY entry point ─────────
  # The bedrock→vLLM live failure (codex_fuck_up.txt): a Claude→Bedrock tool
  # request carried provider: :bedrock but routed to vLLM, because only the
  # discoverable providers (ollama/mlx/vllm) get auto-rules and resolve_chain's
  # chain_from_intent honors a provider hint only as a scoring bonus — with no
  # bedrock rule to boost, the vLLM rule wins. Router.resolve already falls
  # through to explicit_resolution (router_spec.rb); resolve_chain MUST reach the
  # same primary. (NxN G14 routing consolidation / redesign issue #95.)
  describe 'explicit provider hint parity across resolve and resolve_chain' do
    before do
      # Only a vLLM rule exists — bedrock has no auto-rule, exactly like the live
      # daemon where RuleGenerator emits rules only for ollama/mlx/vllm.
      configure_with_rules(
        [
          {
            name:     'chat-vllm',
            when:     { operation: 'chat' },
            then:     {
              tier: 'direct', provider: 'vllm', instance: 'apollo',
              model: 'legion-code-27b-v1', model_capabilities: %i[completion streaming tools]
            },
            priority: 100
          }
        ]
      )
      # Bedrock is a registered, serveable provider with a default model.
      Legion::LLM::Call::Registry.register(
        :bedrock, Module.new,
        metadata: { tier: :cloud, default_model: 'anthropic.claude-sonnet-4' }
      )
      # Isolate the bug from availability: keep every candidate so a vLLM primary
      # proves the hint was ignored, not that availability filtered vLLM out.
      allow(Legion::LLM::Router::Availability).to receive(:filter_resolutions) { |resolutions, **| resolutions }
    end

    after { Legion::LLM::Call::Registry.deregister_provider(:bedrock) }

    let(:bedrock_hint_intent) { { operation: :chat, effort: :moderate, required_capabilities: [:tools] } }

    it 'Router.resolve routes an explicit bedrock hint to bedrock, not the vLLM rule' do
      result = Legion::LLM::Router.resolve(provider: :bedrock, intent: bedrock_hint_intent)
      expect(result.provider).to eq(:bedrock)
    end

    it 'Router.resolve_chain primary routes an explicit bedrock hint to bedrock, not the vLLM rule' do
      chain = Legion::LLM::Router.resolve_chain(provider: :bedrock, intent: bedrock_hint_intent)
      expect(chain.primary.provider).to eq(:bedrock)
    end
  end

  # Regression: the anthropic->qwen e2e failure. The request hinted provider=anthropic
  # with no model; the per-instance default was stale and routing leaked a foreign
  # global default (qwen) onto anthropic. explicit_resolution now sources the model
  # from Inventory (the SSOT, already whitelist-filtered), so an explicit provider is
  # paired only with a model it actually offers — never a foreign/stale one.
  describe 'explicit provider sources its model from Inventory, never a foreign default' do
    before do
      configure_with_rules([])
      # Registry carries a stale/contaminated default for anthropic (qwen) — the bug.
      Legion::LLM::Call::Registry.register(
        :anthropic, Module.new,
        metadata: { tier: :frontier, default_model: 'qwen3.6-27b' }
      )
      allow(Legion::LLM::Router::Availability).to receive(:filter_resolutions) { |resolutions, **| resolutions }
      # Inventory (SSOT) knows anthropic offers only haiku.
      allow(Legion::LLM::Inventory).to receive(:routing_candidates).and_call_original
      allow(Legion::LLM::Inventory).to receive(:routing_candidates).with(provider: :anthropic).and_return(
        [{ model: 'claude-haiku-4-5-20251001', provider_family: 'anthropic', instance_id: 'primary' }]
      )
      # inventory_default_model now calls lanes_for instead of routing_candidates (P1 commit 1)
      allow(Legion::LLM::Inventory).to receive(:lanes_for).and_call_original
      allow(Legion::LLM::Inventory).to receive(:lanes_for).with(provider: :anthropic, type: :inference).and_return(
        [{ model: 'claude-haiku-4-5-20251001', provider_family: 'anthropic', instance_id: 'primary' }]
      )
    end

    after { Legion::LLM::Call::Registry.deregister_provider(:anthropic) }

    it 'resolves anthropic to its Inventory model, not the stale registry/global default' do
      result = Legion::LLM::Router.resolve(provider: :anthropic, intent: { operation: :chat, effort: :moderate })
      expect(result.provider).to eq(:anthropic)
      expect(result.model).to eq('claude-haiku-4-5-20251001')
    end

    it 'reaches the same Inventory-sourced model via resolve_chain' do
      chain = Legion::LLM::Router.resolve_chain(provider: :anthropic, intent: { operation: :chat, effort: :moderate })
      expect([chain.primary.provider, chain.primary.model]).to eq([:anthropic, 'claude-haiku-4-5-20251001'])
    end
  end
end
