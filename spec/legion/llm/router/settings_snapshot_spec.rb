# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/settings_snapshot'

RSpec.describe Legion::LLM::Router::SettingsSnapshot do
  # ------------------------------------------------------------------ #
  # Helpers                                                              #
  # ------------------------------------------------------------------ #

  def valid_routing
    {
      tier_weights:                      { direct: 105, local: 110, fleet: 110, cloud: 120, frontier: 150 },
      context_headroom_ppm:              900_000,
      input_framing_overhead_tokens:     1_024,
      affinity_strength_bps:             10_000,
      max_attempts:                      3,
      allow_body_routing_hints:          false,
      body_model_hint_whitelist:         [],
      body_model_hint_blacklist:         [],
      auto_routing_model_aliases:        %w[legionio auto copilot-utility-small],
      auto_routing_model_alias_metadata: {
        'copilot-utility-small' => { owned_by: 'legionio' }
      }
    }
  end

  def valid_api
    { routing_too_early_retry_after: 1 }
  end

  def valid_llm_settings
    { routing: valid_routing, api: valid_api }
  end

  def valid_ext
    { llm: {} }
  end

  def build(**overrides)
    described_class.build(
      generation:         overrides.fetch(:generation, 1),
      llm_settings:       overrides.fetch(:llm_settings, valid_llm_settings),
      extension_settings: overrides.fetch(:extension_settings, valid_ext)
    )
  end

  # ------------------------------------------------------------------ #
  # Happy-path build                                                     #
  # ------------------------------------------------------------------ #

  describe '.build' do
    it 'returns a frozen SettingsSnapshot with the expected readers' do
      snap = build
      expect(snap).to be_frozen
      expect(snap.generation).to eq(1)
      expect(snap.tier_weights).to eq(direct: 105, local: 110, fleet: 110, cloud: 120, frontier: 150)
      expect(snap.context_headroom_ppm).to eq(900_000)
      expect(snap.input_framing_overhead_tokens).to eq(1_024)
      expect(snap.affinity_strength_bps).to eq(10_000)
      expect(snap.maximum_attempts).to eq(3)
      expect(snap.routing_too_early_retry_after).to eq(1)
      expect(snap.allow_body_routing_hints).to eq(false)
      expect(snap.body_model_hint_whitelist).to eq([])
      expect(snap.body_model_hint_blacklist).to eq([])
      expect(snap.auto_routing_model_aliases).to include('copilot-utility-small')
      expect(snap.auto_routing_model_alias_metadata['copilot-utility-small'][:owned_by]).to eq('legionio')
    end

    it 'returns the same frozen tier_weights hash' do
      snap = build
      expect(snap.tier_weights).to be_frozen
    end
  end

  # ------------------------------------------------------------------ #
  # Validation rejections                                               #
  # ------------------------------------------------------------------ #

  describe 'validation' do
    it 'rejects a negative generation' do
      expect { build(generation: -1) }.to raise_error(ArgumentError, /generation/)
    end

    it 'rejects a zero generation' do
      expect { build(generation: 0) }.to raise_error(ArgumentError, /generation/)
    end

    it 'rejects a float generation' do
      expect { build(generation: 1.5) }.to raise_error(ArgumentError, /generation/)
    end

    it 'rejects a negative tier weight' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(tier_weights: valid_routing[:tier_weights].merge(direct: -1)))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /tier_weights/)
    end

    it 'rejects a float tier weight' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(tier_weights: valid_routing[:tier_weights].merge(local: 1.5)))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /tier_weights/)
    end

    it 'rejects a string tier weight' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(tier_weights: valid_routing[:tier_weights].merge(fleet: 'high')))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /tier_weights/)
    end

    it 'rejects tier_weights with extra keys' do
      extra = valid_routing[:tier_weights].merge(unknown: 10)
      llm = valid_llm_settings.merge(routing: valid_routing.merge(tier_weights: extra))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /tier_weights/)
    end

    it 'rejects context_headroom_ppm of zero' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(context_headroom_ppm: 0))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /context_headroom_ppm/)
    end

    it 'rejects context_headroom_ppm greater than 1_000_000' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(context_headroom_ppm: 1_000_001))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /context_headroom_ppm/)
    end

    it 'rejects a float context_headroom_ppm' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(context_headroom_ppm: 0.9))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /context_headroom_ppm/)
    end

    it 'rejects a negative input_framing_overhead_tokens' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(input_framing_overhead_tokens: -1))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /input_framing_overhead_tokens/)
    end

    it 'rejects a float input_framing_overhead_tokens' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(input_framing_overhead_tokens: 1.5))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /input_framing_overhead_tokens/)
    end

    it 'rejects affinity_strength_bps out of range' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(affinity_strength_bps: 10_001))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /affinity_strength_bps/)
    end

    it 'rejects a negative affinity_strength_bps' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(affinity_strength_bps: -1))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /affinity_strength_bps/)
    end

    it 'rejects max_attempts of zero' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(max_attempts: 0))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /maximum_attempts/)
    end

    it 'rejects a float max_attempts' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(max_attempts: 1.5))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /maximum_attempts/)
    end

    it 'rejects routing_too_early_retry_after of zero' do
      llm = valid_llm_settings.merge(api: { routing_too_early_retry_after: 0 })
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /routing_too_early_retry_after/)
    end

    it 'rejects routing_too_early_retry_after of 31' do
      llm = valid_llm_settings.merge(api: { routing_too_early_retry_after: 31 })
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /routing_too_early_retry_after/)
    end

    it 'rejects non-boolean allow_body_routing_hints' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(allow_body_routing_hints: 'yes'))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /allow_body_routing_hints/)
    end

    it 'rejects a blank string in body_model_hint_whitelist' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(body_model_hint_whitelist: ['']))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /body_model_hint_whitelist/)
    end

    it 'rejects a non-string entry in body_model_hint_blacklist' do
      llm = valid_llm_settings.merge(routing: valid_routing.merge(body_model_hint_blacklist: [123]))
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /body_model_hint_blacklist/)
    end

    it 'rejects alias metadata for an alias not in auto_routing_model_aliases' do
      meta = { 'unknown-alias' => { owned_by: 'test' } }
      routing = valid_routing.merge(auto_routing_model_alias_metadata: meta)
      llm = valid_llm_settings.merge(routing: routing)
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /alias/)
    end

    it 'rejects alias metadata with unknown keys' do
      meta = { 'copilot-utility-small' => { owned_by: 'legionio', bad_key: 'x' } }
      routing = valid_routing.merge(auto_routing_model_alias_metadata: meta)
      llm = valid_llm_settings.merge(routing: routing)
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /bad_key/)
    end

    it 'rejects alias metadata created with a negative integer' do
      meta = { 'copilot-utility-small' => { owned_by: 'legionio', created: -1 } }
      routing = valid_routing.merge(auto_routing_model_alias_metadata: meta)
      llm = valid_llm_settings.merge(routing: routing)
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /created/)
    end
  end

  # ------------------------------------------------------------------ #
  # Legacy context_headroom Float → ppm deprecation conversion          #
  # ------------------------------------------------------------------ #

  describe 'legacy context_headroom deprecation' do
    it 'converts context_headroom 0.9 to 900_000 and emits a warning' do
      # Remove context_headroom_ppm so the legacy key takes precedence.
      routing = valid_routing.except(:context_headroom_ppm).merge(context_headroom: 0.9)
      llm = valid_llm_settings.merge(routing: routing)

      snap = nil
      expect { snap = build(llm_settings: llm) }.not_to raise_error
      expect(snap.context_headroom_ppm).to eq(900_000)
    end

    it 'converts context_headroom 1.0 to 1_000_000' do
      routing = valid_routing.except(:context_headroom_ppm).merge(context_headroom: 1.0)
      llm = valid_llm_settings.merge(routing: routing)
      snap = build(llm_settings: llm)
      expect(snap.context_headroom_ppm).to eq(1_000_000)
    end

    it 'converts context_headroom 0.5 to 500_000' do
      routing = valid_routing.except(:context_headroom_ppm).merge(context_headroom: 0.5)
      llm = valid_llm_settings.merge(routing: routing)
      snap = build(llm_settings: llm)
      expect(snap.context_headroom_ppm).to eq(500_000)
    end

    it 'rejects context_headroom of 0.0' do
      routing = valid_routing.except(:context_headroom_ppm).merge(context_headroom: 0.0)
      llm = valid_llm_settings.merge(routing: routing)
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /context_headroom/)
    end

    it 'rejects context_headroom greater than 1.0' do
      routing = valid_routing.except(:context_headroom_ppm).merge(context_headroom: 1.1)
      llm = valid_llm_settings.merge(routing: routing)
      expect { build(llm_settings: llm) }.to raise_error(ArgumentError, /context_headroom/)
    end
  end

  # ------------------------------------------------------------------ #
  # weight_inputs_for — missing-component identity 1 cascade            #
  # ------------------------------------------------------------------ #

  describe '#weight_inputs_for' do
    # Minimal LaneRecord-like stub
    def lane_stub(tier:, provider_family:, instance_id:, model:, offering_id: 'off:v1:abc')
      double(
        'LaneRecord',
        tier:            tier,
        provider_family: provider_family,
        instance_id:     instance_id,
        model:           model,
        offering_id:     offering_id
      )
    end

    it 'returns all identity weights when no extension settings are present' do
      snap = build
      lane = lane_stub(tier: :local, provider_family: :vllm, instance_id: 'h200', model: 'gemma4')
      wi = snap.weight_inputs_for(lane: lane)
      expect(wi[:tier]).to eq(110)         # from tier_weights[:local]
      expect(wi[:provider]).to eq(1)       # missing in extension_settings
      expect(wi[:instance]).to eq(1)       # missing
      expect(wi[:model_or_offering]).to eq(1) # missing
    end

    it 'returns configured provider weight' do
      ext = { llm: { vllm: { weight: 200 } } }
      snap = build(extension_settings: ext)
      lane = lane_stub(tier: :local, provider_family: :vllm, instance_id: 'h200', model: 'gemma4')
      expect(snap.weight_inputs_for(lane: lane)[:provider]).to eq(200)
    end

    it 'returns configured instance weight' do
      ext = { llm: { vllm: { instances: { h200: { weight: 150 } } } } }
      snap = build(extension_settings: ext)
      lane = lane_stub(tier: :direct, provider_family: :vllm, instance_id: 'h200', model: 'gemma4')
      expect(snap.weight_inputs_for(lane: lane)[:instance]).to eq(150)
    end

    it 'prefers offering weight over model weight' do
      offering_id = 'off:v1:xyz'
      ext = {
        llm: {
          vllm: {
            offerings: { 'off:v1:xyz' => { weight: 300 } },
            models:    { 'gemma4' => { weight: 50 } }
          }
        }
      }
      snap = build(extension_settings: ext)
      lane = lane_stub(tier: :direct, provider_family: :vllm, instance_id: 'h200', model: 'gemma4', offering_id: offering_id)
      expect(snap.weight_inputs_for(lane: lane)[:model_or_offering]).to eq(300)
    end

    it 'falls back to model weight when offering weight absent' do
      ext = { llm: { vllm: { models: { 'gemma4' => { weight: 75 } } } } }
      snap = build(extension_settings: ext)
      lane = lane_stub(tier: :cloud, provider_family: :vllm, instance_id: 'h200', model: 'gemma4')
      expect(snap.weight_inputs_for(lane: lane)[:model_or_offering]).to eq(75)
    end

    it 'returns frozen weight_inputs hash' do
      snap = build
      lane = lane_stub(tier: :frontier, provider_family: :vllm, instance_id: 'h200', model: 'gemma4')
      expect(snap.weight_inputs_for(lane: lane)).to be_frozen
    end

    it 'returns zero tier weight when tier weight is zero (disabled)' do
      routing = valid_routing.merge(tier_weights: valid_routing[:tier_weights].merge(fleet: 0))
      snap = build(llm_settings: valid_llm_settings.merge(routing: routing))
      lane = lane_stub(tier: :fleet, provider_family: :vllm, instance_id: 'h200', model: 'gemma4')
      expect(snap.weight_inputs_for(lane: lane)[:tier]).to eq(0)
    end
  end

  # ------------------------------------------------------------------ #
  # preferred_context_range_for                                         #
  # ------------------------------------------------------------------ #

  describe '#preferred_context_range_for' do
    def lane_stub(provider_family:, instance_id:)
      double('LaneRecord', tier: :direct, provider_family: provider_family, instance_id: instance_id,
                           model: 'gemma4', offering_id: 'off:v1:abc')
    end

    it 'returns nil when no preferred range is configured' do
      snap = build
      expect(snap.preferred_context_range_for(lane: lane_stub(provider_family: :vllm, instance_id: 'h200'))).to be_nil
    end

    it 'returns the configured preferred range' do
      ext = { llm: { vllm: { instances: { h200: { preferred_min_context_tokens: 1024, preferred_max_context_tokens: 8192 } } } } }
      snap = build(extension_settings: ext)
      range = snap.preferred_context_range_for(lane: lane_stub(provider_family: :vllm, instance_id: 'h200'))
      expect(range).to eq({ min: 1024, max: 8192 })
      expect(range).to be_frozen
    end

    it 'returns nil for an unknown instance' do
      ext = { llm: { vllm: { instances: { h200: { preferred_min_context_tokens: 1024 } } } } }
      snap = build(extension_settings: ext)
      expect(snap.preferred_context_range_for(lane: lane_stub(provider_family: :vllm, instance_id: 'other'))).to be_nil
    end
  end

  # ------------------------------------------------------------------ #
  # capability_override_for — cascaded enable_<cap> (fail-forward)      #
  # ------------------------------------------------------------------ #

  describe '#capability_override_for' do
    it 'resolves the instance-level (config-name keyed) enable_* value' do
      ext = { llm: { vllm: { instances: { 'h200' => { enable_thinking: true } } } } }
      snap = build(extension_settings: ext)
      expect(
        snap.capability_override_for(provider_family: :vllm, instance_id: 'h200',
                                     capability: :thinking, model: 'gemma4')
      ).to be(true)
    end

    it 'preserves an explicit false (not a missing value)' do
      ext = { llm: { vllm: { instances: { h200: { enable_thinking: false } } } } }
      snap = build(extension_settings: ext)
      expect(
        snap.capability_override_for(provider_family: :vllm, instance_id: 'h200',
                                     capability: :thinking, model: 'gemma4')
      ).to be(false)
    end

    it 'falls through to the provider leg when the instance leg is unset' do
      ext = { llm: { vllm: { enable_thinking: true, instances: { h200: { weight: 1 } } } } }
      snap = build(extension_settings: ext)
      expect(
        snap.capability_override_for(provider_family: :vllm, instance_id: 'h200',
                                     capability: :thinking, model: 'gemma4')
      ).to be(true)
    end

    it 'lets the model leg beat the instance leg (most-specific-first)' do
      ext = {
        llm: {
          vllm: {
            instances: {
              h200: {
                enable_thinking: true,
                models:          { 'gemma4' => { enable_thinking: false } }
              }
            }
          }
        }
      }
      snap = build(extension_settings: ext)
      expect(
        snap.capability_override_for(provider_family: :vllm, instance_id: 'h200',
                                     capability: :thinking, model: 'gemma4')
      ).to be(false)
    end

    it 'returns nil when no scope carries the key' do
      snap = build
      expect(
        snap.capability_override_for(provider_family: :vllm, instance_id: 'h200',
                                     capability: :thinking, model: 'gemma4')
      ).to be_nil
    end

    it 'returns nil for an unknown instance' do
      ext = { llm: { vllm: { instances: { h200: { enable_thinking: true } } } } }
      snap = build(extension_settings: ext)
      expect(
        snap.capability_override_for(provider_family: :vllm, instance_id: 'other',
                                     capability: :thinking, model: 'gemma4')
      ).to be_nil
    end
  end

  # ------------------------------------------------------------------ #
  # Cascade legs — weight + preferred range keyed by config name        #
  # ------------------------------------------------------------------ #

  describe 'cascade legs' do
    def lane_stub(tier:, provider_family:, instance_id:, model:, offering_id: 'off:v1:abc')
      double(
        'LaneRecord',
        tier:            tier,
        provider_family: provider_family,
        instance_id:     instance_id,
        model:           model,
        offering_id:     offering_id
      )
    end

    it 'resolves the instance-scoped models.<model> weight before the provider-scoped one' do
      ext = {
        llm: {
          vllm: {
            models:    { 'gemma4' => { weight: 50 } },
            instances: { 'h200' => { models: { 'gemma4' => { weight: 150 } } } }
          }
        }
      }
      snap = build(extension_settings: ext)
      lane = lane_stub(tier: :local, provider_family: :vllm, instance_id: 'h200', model: 'gemma4')
      expect(snap.weight_inputs_for(lane: lane)[:model_or_offering]).to eq(150)
    end

    it 'still prefers the offering weight over any model-scope weight' do
      ext = {
        llm: {
          vllm: {
            offerings: { 'off:v1:xyz' => { weight: 300 } },
            instances: { 'h200' => { models: { 'gemma4' => { weight: 150 } } } }
          }
        }
      }
      snap = build(extension_settings: ext)
      lane = lane_stub(tier: :local, provider_family: :vllm, instance_id: 'h200',
                       model: 'gemma4', offering_id: 'off:v1:xyz')
      expect(snap.weight_inputs_for(lane: lane)[:model_or_offering]).to eq(300)
    end

    it 'resolves a preferred range from a provider-level leg' do
      ext = { llm: { vllm: { preferred_max_context_tokens: 8192 } } }
      snap = build(extension_settings: ext)
      lane = lane_stub(tier: :local, provider_family: :vllm, instance_id: 'h200', model: 'gemma4')
      expect(snap.preferred_context_range_for(lane: lane)).to eq({ min: nil, max: 8192 })
    end

    it 'merges instance-level min with provider-level max (per-key cascade)' do
      ext = {
        llm: {
          vllm: {
            preferred_max_context_tokens: 8192,
            instances:                    { 'h200' => { preferred_min_context_tokens: 1024 } }
          }
        }
      }
      snap = build(extension_settings: ext)
      lane = lane_stub(tier: :local, provider_family: :vllm, instance_id: 'h200', model: 'gemma4')
      expect(snap.preferred_context_range_for(lane: lane)).to eq({ min: 1024, max: 8192 })
    end

    it 'lets the model leg override the instance preferred bounds' do
      ext = {
        llm: {
          vllm: {
            instances: {
              'h200' => {
                preferred_min_context_tokens: 1024,
                models:                       { 'gemma4' => { preferred_min_context_tokens: 2048 } }
              }
            }
          }
        }
      }
      snap = build(extension_settings: ext)
      lane = lane_stub(tier: :local, provider_family: :vllm, instance_id: 'h200', model: 'gemma4')
      expect(snap.preferred_context_range_for(lane: lane)).to eq({ min: 2048, max: nil })
    end
  end

  # ------------------------------------------------------------------ #
  # model_policy_for — §9.5 specificity cascade                         #
  # ------------------------------------------------------------------ #

  describe '#model_policy_for' do
    def offering_stub(provider_family:, instance_id:)
      ik = double('InstanceKey', provider_family: provider_family, instance_id: instance_id)
      double('OfferingRecord', instance_key: ik, model: 'gemma4')
    end

    it 'returns empty whitelist and blacklist when nothing is configured' do
      snap = build
      policy = snap.model_policy_for(offering: offering_stub(provider_family: :vllm, instance_id: 'h200'))
      expect(policy[:whitelist]).to eq([])
      expect(policy[:blacklist]).to eq([])
    end

    it 'uses instance-level policy when configured (most specific wins)' do
      ext = {
        llm: {
          vllm: {
            model_whitelist: %w[global-allowed],
            instances:       {
              h200: { model_whitelist: %w[instance-allowed] }
            }
          }
        }
      }
      snap = build(extension_settings: ext)
      policy = snap.model_policy_for(offering: offering_stub(provider_family: :vllm, instance_id: 'h200'))
      expect(policy[:whitelist]).to eq(%w[instance-allowed])
    end

    it 'falls through to provider-level when instance key is absent' do
      ext = {
        llm: {
          vllm: {
            model_whitelist: %w[provider-allowed],
            instances:       { h200: { weight: 1 } } # no :model_whitelist key
          }
        }
      }
      snap = build(extension_settings: ext)
      policy = snap.model_policy_for(offering: offering_stub(provider_family: :vllm, instance_id: 'h200'))
      expect(policy[:whitelist]).to eq(%w[provider-allowed])
    end

    it 'falls through to global when both provider and instance lack the key' do
      ext = {
        llm: {
          model_whitelist: %w[global-allowed],
          vllm:            { weight: 1 }
        }
      }
      snap = build(extension_settings: ext)
      policy = snap.model_policy_for(offering: offering_stub(provider_family: :vllm, instance_id: 'h200'))
      expect(policy[:whitelist]).to eq(%w[global-allowed])
    end

    it 'instance-level explicit empty array beats provider-level nonempty list' do
      ext = {
        llm: {
          vllm: {
            model_whitelist: %w[provider-allowed],
            instances:       { h200: { model_whitelist: [] } }
          }
        }
      }
      snap = build(extension_settings: ext)
      policy = snap.model_policy_for(offering: offering_stub(provider_family: :vllm, instance_id: 'h200'))
      expect(policy[:whitelist]).to eq([])
    end

    it 'resolves blacklist independently from whitelist' do
      ext = {
        llm: {
          vllm: {
            model_blacklist: %w[provider-denied],
            instances:       { h200: { model_whitelist: %w[instance-allowed] } }
          }
        }
      }
      snap = build(extension_settings: ext)
      policy = snap.model_policy_for(offering: offering_stub(provider_family: :vllm, instance_id: 'h200'))
      expect(policy[:whitelist]).to eq(%w[instance-allowed])
      expect(policy[:blacklist]).to eq(%w[provider-denied])
    end

    it 'returns frozen policy hash' do
      snap = build
      policy = snap.model_policy_for(offering: offering_stub(provider_family: :vllm, instance_id: 'h200'))
      expect(policy).to be_frozen
    end
  end
end
