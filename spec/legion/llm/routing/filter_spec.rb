# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/routing/filter'

RSpec.describe Legion::LLM::Routing::Filter do
  let(:filter_class) do
    Class.new do
      include Legion::LLM::Routing::Filter
    end
  end

  let(:filter) { filter_class.new }

  # ---------------------------------------------------------------------------
  # Helpers for building lane-like test doubles
  # ---------------------------------------------------------------------------

  def lane_double(attrs = {})
    ik = attrs.delete(:instance_key) || instance_key_double(
      provider_family: attrs.delete(:provider_family) || :vllm,
      instance_id:     attrs.delete(:instance_id) || 'h200'
    )
    defaults = {
      model:                         'gemma4',
      tier:                          :direct,
      operation:                     :chat,
      instance_key:                  ik,
      metadata:                      {},
      weight_inputs:                 { tier: 100, provider: 100, instance: 100, model_or_offering: 100 },
      capability_evidence:           {},
      context_evidence:              unknown_evidence,
      embedding_dimensions_evidence: unknown_evidence,
      quota_domain:                  nil,
      lane_id:                       'direct:vllm:h200:inference:gemma4'
    }
    double('LaneRecord', defaults.merge(attrs))
  end

  def instance_key_double(provider_family: :vllm, instance_id: 'h200')
    double('InstanceKey', provider_family: provider_family, instance_id: instance_id)
  end

  def unknown_evidence
    double('ValueEvidence', known?: false, status: :unknown, value: nil)
  end

  def known_evidence(value)
    double('ValueEvidence', known?: true, status: :known, value: value)
  end

  def capability_ev(capability, status)
    double('CapabilityEvidence', capability: capability, status: status)
  end

  def exclusion_double(target_kind:, target:)
    double('Exclusion', target_kind: target_kind, target: target)
  end

  # ---------------------------------------------------------------------------
  # Input extractors: filter_type, filter_provider, filter_instance, etc.
  # ---------------------------------------------------------------------------

  describe '#filter_type' do
    it 'returns the type Symbol when a Symbol is passed' do
      expect(filter.filter_type(type: :inference)).to eq(:inference)
    end

    it 'returns nil when no type is constrained' do
      expect(filter.filter_type).to be_nil
    end

    it 'returns nil when type is not a Symbol' do
      expect(filter.filter_type(type: 'inference')).to be_nil
    end
  end

  describe '#filter_provider' do
    it 'returns the provider Symbol when a Symbol is passed' do
      expect(filter.filter_provider(provider: :anthropic)).to eq(:anthropic)
    end

    it 'returns nil when no provider is constrained' do
      expect(filter.filter_provider).to be_nil
    end

    it 'returns nil when provider is not a Symbol' do
      expect(filter.filter_provider(provider: 'anthropic')).to be_nil
    end
  end

  describe '#filter_instance' do
    it 'returns the instance String when a String is passed' do
      expect(filter.filter_instance(instance: 'h200')).to eq('h200')
    end

    it 'returns nil when no instance is constrained' do
      expect(filter.filter_instance).to be_nil
    end

    it 'returns nil when instance is not a String' do
      expect(filter.filter_instance(instance: :h200)).to be_nil
    end
  end

  describe '#filter_tier' do
    it 'returns the tier Symbol when a Symbol is passed' do
      expect(filter.filter_tier(tier: :local)).to eq(:local)
    end

    it 'returns nil when no tier is constrained' do
      expect(filter.filter_tier).to be_nil
    end

    it 'returns nil when tier is not a Symbol' do
      expect(filter.filter_tier(tier: 'local')).to be_nil
    end
  end

  describe '#filter_capability' do
    it 'returns a frozen array of capabilities when present' do
      result = filter.filter_capability(capabilities: %i[vision tools])
      expect(result).to eq(%i[vision tools])
      expect(result).to be_frozen
    end

    it 'returns nil when no capabilities are required' do
      expect(filter.filter_capability).to be_nil
    end

    it 'returns nil when capabilities array is empty' do
      expect(filter.filter_capability(capabilities: [])).to be_nil
    end

    it 'compacts nil entries' do
      expect(filter.filter_capability(capabilities: [nil, :tools, nil])).to eq([:tools])
    end
  end

  describe '#filter_context' do
    it 'returns the context Integer when an Integer is passed' do
      expect(filter.filter_context(context: 32_000)).to eq(32_000)
    end

    it 'returns nil when no context is constrained' do
      expect(filter.filter_context).to be_nil
    end

    it 'returns nil when context is not an Integer' do
      expect(filter.filter_context(context: 32_000.5)).to be_nil
    end
  end

  describe '#filter_embedding_dimensions' do
    it 'returns the dimensions Integer when an Integer is passed' do
      expect(filter.filter_embedding_dimensions(embedding_dimensions: 1536)).to eq(1536)
    end

    it 'returns nil when no dimensions are constrained' do
      expect(filter.filter_embedding_dimensions).to be_nil
    end

    it 'returns nil when dimensions is not an Integer' do
      expect(filter.filter_embedding_dimensions(embedding_dimensions: '1536')).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # filter_policy — model whitelist/blacklist
  # ---------------------------------------------------------------------------

  describe '#filter_policy' do
    it 'returns :allowed when both whitelist and blacklist are empty' do
      lane = lane_double(model: 'gemma4')
      expect(filter.filter_policy(lane: lane, whitelist: [], blacklist: [])).to eq(:allowed)
    end

    it 'returns :denied when model matches a blacklist entry (case-insensitive substring)' do
      lane = lane_double(model: 'Claude-3-Haiku')
      expect(filter.filter_policy(lane: lane, whitelist: [], blacklist: ['haiku'])).to eq(:denied)
    end

    it 'returns :denied when model is not in a non-empty whitelist' do
      lane = lane_double(model: 'gemma4')
      expect(filter.filter_policy(lane: lane, whitelist: ['claude'], blacklist: [])).to eq(:denied)
    end

    it 'returns :allowed when model matches the whitelist' do
      lane = lane_double(model: 'claude-3-opus')
      expect(filter.filter_policy(lane: lane, whitelist: ['claude'], blacklist: [])).to eq(:allowed)
    end

    it 'blacklist wins over whitelist when both match' do
      lane = lane_double(model: 'claude-3-haiku')
      expect(filter.filter_policy(lane: lane, whitelist: ['claude'], blacklist: ['haiku'])).to eq(:denied)
    end

    it 'matching is case-insensitive' do
      lane = lane_double(model: 'GEMMA4-LARGE')
      expect(filter.filter_policy(lane: lane, whitelist: ['gemma4'], blacklist: [])).to eq(:allowed)
    end
  end

  # ---------------------------------------------------------------------------
  # filter_availability
  # ---------------------------------------------------------------------------

  describe '#filter_availability' do
    it 'returns :available when the instance availability state is :available' do
      avail = double('AvailabilityFact', state: :available)
      instance = double('InstanceRecord', availability: avail)
      expect(filter.filter_availability(instance: instance)).to eq(:available)
    end

    it 'returns :unavailable when the instance availability state is :unavailable' do
      avail = double('AvailabilityFact', state: :unavailable)
      instance = double('InstanceRecord', availability: avail)
      expect(filter.filter_availability(instance: instance)).to eq(:unavailable)
    end

    it 'returns :unknown when the instance is nil' do
      expect(filter.filter_availability(instance: nil)).to eq(:unknown)
    end

    it 'returns :unknown when availability is nil' do
      instance = double('InstanceRecord', availability: nil)
      expect(filter.filter_availability(instance: instance)).to eq(:unknown)
    end

    it 'returns :unknown when availability state is an unrecognized value' do
      avail = double('AvailabilityFact', state: :initializing)
      instance = double('InstanceRecord', availability: avail)
      expect(filter.filter_availability(instance: instance)).to eq(:unknown)
    end
  end

  # ---------------------------------------------------------------------------
  # filter_fleet — fleet contract evaluation
  # ---------------------------------------------------------------------------

  describe '#filter_fleet' do
    it 'returns :not_applicable for a non-fleet tier' do
      lane = lane_double(tier: :direct, metadata: {})
      expect(filter.filter_fleet(lane: lane)).to eq(:not_applicable)
    end

    it 'returns :supported for a fleet lane with exact_offering_v1 contract' do
      lane = lane_double(tier: :fleet, metadata: { fleet_execution_contract: 'exact_offering_v1' })
      expect(filter.filter_fleet(lane: lane)).to eq(:supported)
    end

    it 'returns :legacy for a fleet lane with no contract' do
      lane = lane_double(tier: :fleet, metadata: {})
      expect(filter.filter_fleet(lane: lane)).to eq(:legacy)
    end

    it 'returns :legacy for a fleet lane with empty string contract' do
      lane = lane_double(tier: :fleet, metadata: { fleet_execution_contract: '' })
      expect(filter.filter_fleet(lane: lane)).to eq(:legacy)
    end

    it 'returns :legacy for a fleet lane with nil contract' do
      lane = lane_double(tier: :fleet, metadata: { fleet_execution_contract: nil })
      expect(filter.filter_fleet(lane: lane)).to eq(:legacy)
    end

    it 'returns :unknown for a fleet lane with an unrecognized contract' do
      lane = lane_double(tier: :fleet, metadata: { fleet_execution_contract: 'unknown_contract_v99' })
      expect(filter.filter_fleet(lane: lane)).to eq(:unknown)
    end
  end

  # ---------------------------------------------------------------------------
  # filter_weight — lane weight evaluation
  # ---------------------------------------------------------------------------

  describe '#filter_weight' do
    it 'returns :enabled when all weight inputs are positive' do
      lane = lane_double(weight_inputs: { tier: 100, provider: 100, instance: 100, model_or_offering: 100 })
      expect(filter.filter_weight(lane: lane)).to eq(:enabled)
    end

    it 'returns :disabled when any weight input is zero' do
      lane = lane_double(weight_inputs: { tier: 100, provider: 100, instance: 0, model_or_offering: 100 })
      expect(filter.filter_weight(lane: lane)).to eq(:disabled)
    end

    it 'returns :disabled when weight_inputs is nil' do
      lane = lane_double(weight_inputs: nil)
      expect(filter.filter_weight(lane: lane)).to eq(:disabled)
    end
  end

  # ---------------------------------------------------------------------------
  # filter_operation — operation axis (step 1)
  # ---------------------------------------------------------------------------

  describe '#filter_operation' do
    it 'returns :supported when lane operation maps to same type as requested operation' do
      lane = lane_double(operation: :chat)
      expect(filter.filter_operation(lane: lane, operation: :chat)).to eq(:supported)
    end

    it 'returns :supported when lane is stream_chat and request is chat (both inference)' do
      lane = lane_double(operation: :stream_chat)
      expect(filter.filter_operation(lane: lane, operation: :chat)).to eq(:supported)
    end

    it 'returns :unsupported when lane operation type differs from requested operation type' do
      lane = lane_double(operation: :chat)
      expect(filter.filter_operation(lane: lane, operation: :embed)).to eq(:unsupported)
    end

    it 'returns :supported for embed → embed (both embedding type)' do
      lane = lane_double(operation: :embed)
      expect(filter.filter_operation(lane: lane, operation: :embed)).to eq(:supported)
    end

    it 'returns :unsupported for embed lane vs chat request' do
      lane = lane_double(operation: :embed)
      expect(filter.filter_operation(lane: lane, operation: :chat)).to eq(:unsupported)
    end

    it 'returns :supported for audio operations (transcribe → translate both audio)' do
      lane = lane_double(operation: :transcribe)
      expect(filter.filter_operation(lane: lane, operation: :translate)).to eq(:supported)
    end
  end

  # ---------------------------------------------------------------------------
  # filter_pins — provider/instance/model/tier pins (step 2)
  # ---------------------------------------------------------------------------

  describe '#filter_pins' do
    let(:ik) { instance_key_double(provider_family: :anthropic, instance_id: 'cloud1') }
    let(:lane) { lane_double(instance_key: ik, model: 'claude-3', tier: :cloud) }

    it 'returns :match when no pins are set' do
      expect(filter.filter_pins(lane: lane)).to eq(:match)
    end

    it 'returns :match when provider_pin matches' do
      expect(filter.filter_pins(lane: lane, provider_pin: :anthropic)).to eq(:match)
    end

    it 'returns :mismatch when provider_pin does not match' do
      expect(filter.filter_pins(lane: lane, provider_pin: :openai)).to eq(:mismatch)
    end

    it 'returns :match when instance_pin matches' do
      expect(filter.filter_pins(lane: lane, instance_pin: 'cloud1')).to eq(:match)
    end

    it 'returns :mismatch when instance_pin does not match' do
      expect(filter.filter_pins(lane: lane, instance_pin: 'other')).to eq(:mismatch)
    end

    it 'returns :match when model_pin matches' do
      expect(filter.filter_pins(lane: lane, model_pin: 'claude-3')).to eq(:match)
    end

    it 'returns :mismatch when model_pin does not match' do
      expect(filter.filter_pins(lane: lane, model_pin: 'gpt-4')).to eq(:mismatch)
    end

    it 'returns :match when tier_constraint matches' do
      expect(filter.filter_pins(lane: lane, tier_constraint: :cloud)).to eq(:match)
    end

    it 'returns :mismatch when tier_constraint does not match' do
      expect(filter.filter_pins(lane: lane, tier_constraint: :local)).to eq(:mismatch)
    end

    it 'returns :mismatch on first failing pin (short-circuits)' do
      expect(filter.filter_pins(lane: lane, provider_pin: :openai, model_pin: 'claude-3')).to eq(:mismatch)
    end

    it 'returns :match when all pins match simultaneously' do
      expect(filter.filter_pins(
               lane: lane, provider_pin: :anthropic, instance_pin: 'cloud1',
               model_pin: 'claude-3', tier_constraint: :cloud
             )).to eq(:match)
    end
  end

  # ---------------------------------------------------------------------------
  # evaluate_capabilities — capability reduction (step 4)
  # ---------------------------------------------------------------------------

  describe '#evaluate_capabilities' do
    before do
      Legion::Settings.loader.settings[:extensions] ||= {}
      Legion::Settings.loader.settings[:extensions][:llm] ||= {}
    end

    context 'when no capabilities are required' do
      it 'returns :supported' do
        lane = lane_double(capability_evidence: {})
        expect(filter.evaluate_capabilities(lane: lane, required_capabilities: [])).to eq(:supported)
      end
    end

    context 'when all required capabilities are supported' do
      it 'returns :supported' do
        streaming_ev = capability_ev(:streaming, :supported)
        tools_ev = capability_ev(:tools, :supported)
        lane = lane_double(capability_evidence: { streaming: streaming_ev, tools: tools_ev })
        expect(filter.evaluate_capabilities(lane: lane, required_capabilities: %i[streaming tools])).to eq(:supported)
      end
    end

    context 'when a required capability is authoritatively unsupported' do
      it 'returns :unsupported' do
        streaming_ev = capability_ev(:streaming, :unsupported)
        lane = lane_double(capability_evidence: { streaming: streaming_ev })
        expect(filter.evaluate_capabilities(lane: lane, required_capabilities: %i[streaming])).to eq(:unsupported)
      end
    end

    context 'when a required capability has unknown evidence' do
      it 'returns :unknown' do
        lane = lane_double(capability_evidence: {})
        expect(filter.evaluate_capabilities(lane: lane, required_capabilities: %i[thinking])).to eq(:unknown)
      end
    end

    context 'when one capability is unknown and another is unsupported' do
      it 'returns :unknown (unknown takes priority)' do
        vision_ev = capability_ev(:vision, :unsupported)
        lane = lane_double(capability_evidence: { vision: vision_ev })
        # tools is absent → unknown
        expect(filter.evaluate_capabilities(lane: lane, required_capabilities: %i[tools vision])).to eq(:unknown)
      end
    end

    context 'operator enable_* override (SettingsCascade)' do
      let(:ik) { instance_key_double(provider_family: :vllm, instance_id: 'h200') }

      context 'when enable_thinking is true at instance level' do
        before do
          Legion::Settings.loader.settings[:extensions][:llm][:vllm] = {
            instances: { 'h200' => { enable_thinking: true } }
          }
        end

        it 'overrides unknown evidence to :supported' do
          lane = lane_double(instance_key: ik, capability_evidence: {})
          expect(filter.evaluate_capabilities(lane: lane, required_capabilities: %i[thinking])).to eq(:supported)
        end
      end

      context 'when enable_thinking is false at instance level' do
        before do
          Legion::Settings.loader.settings[:extensions][:llm][:vllm] = {
            instances: { 'h200' => { enable_thinking: false } }
          }
        end

        it 'overrides unknown evidence to :unsupported' do
          lane = lane_double(instance_key: ik, capability_evidence: {})
          expect(filter.evaluate_capabilities(lane: lane, required_capabilities: %i[thinking])).to eq(:unsupported)
        end
      end

      context 'when no override is set' do
        it 'falls back to the evidence → :unknown' do
          lane = lane_double(instance_key: ik, capability_evidence: {})
          expect(filter.evaluate_capabilities(lane: lane, required_capabilities: %i[thinking])).to eq(:unknown)
        end
      end

      context 'when the model-level override beats the instance-level override' do
        before do
          Legion::Settings.loader.settings[:extensions][:llm][:vllm] = {
            instances: {
              'h200' => {
                enable_thinking: true,
                models:          { 'gemma4' => { enable_thinking: false } }
              }
            }
          }
        end

        it 'resolves to false (most-specific-first)' do
          lane = lane_double(instance_key: ik, model: 'gemma4', capability_evidence: {})
          expect(filter.evaluate_capabilities(lane: lane, required_capabilities: %i[thinking])).to eq(:unsupported)
        end
      end

      context 'when the provider-level override is the only one set' do
        before do
          Legion::Settings.loader.settings[:extensions][:llm][:vllm] = { enable_thinking: true }
        end

        it 'resolves to true via the provider leg' do
          lane = lane_double(instance_key: ik, capability_evidence: {})
          expect(filter.evaluate_capabilities(lane: lane, required_capabilities: %i[thinking])).to eq(:supported)
        end
      end

      context 'when authoritative evidence is :unsupported' do
        before do
          Legion::Settings.loader.settings[:extensions][:llm][:vllm] = {
            instances: { 'h200' => { enable_thinking: true } }
          }
        end

        it 'does NOT let operator override authoritative :unsupported evidence' do
          thinking_ev = capability_ev(:thinking, :unsupported)
          lane = lane_double(instance_key: ik, capability_evidence: { thinking: thinking_ev })
          expect(filter.evaluate_capabilities(lane: lane, required_capabilities: %i[thinking])).to eq(:unsupported)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # evaluate_context — context budget (step 5)
  # ---------------------------------------------------------------------------

  describe '#evaluate_context' do
    before do
      Legion::Settings.loader.settings[:llm] ||= {}
      Legion::Settings.loader.settings[:llm][:router] ||= {}
      Legion::Settings.loader.settings[:llm][:router][:context_headroom_ppm] = 900_000
    end

    context 'when budget is zero' do
      it 'returns :not_applicable' do
        lane = lane_double(context_evidence: known_evidence(100_000))
        expect(filter.evaluate_context(lane: lane, budget: 0)).to eq(:not_applicable)
      end
    end

    context 'when context evidence is unknown' do
      it 'returns :unknown' do
        lane = lane_double(context_evidence: unknown_evidence)
        expect(filter.evaluate_context(lane: lane, budget: 1_000)).to eq(:unknown)
      end
    end

    context 'when budget fits within the authoritative limit (with headroom)' do
      it 'returns :fits' do
        # context: 100_000; headroom 900_000 ppm → effective limit 90_000
        lane = lane_double(context_evidence: known_evidence(100_000))
        expect(filter.evaluate_context(lane: lane, budget: 89_000)).to eq(:fits)
      end
    end

    context 'when budget exceeds the authoritative limit' do
      it 'returns :rejected' do
        # context: 1_000; headroom 900_000 ppm → effective limit 900
        lane = lane_double(context_evidence: known_evidence(1_000))
        expect(filter.evaluate_context(lane: lane, budget: 901)).to eq(:rejected)
      end
    end

    context 'when budget exactly equals the effective limit' do
      it 'returns :fits' do
        # context: 100_000; headroom 900_000 ppm → effective limit 90_000
        lane = lane_double(context_evidence: known_evidence(100_000))
        expect(filter.evaluate_context(lane: lane, budget: 90_000)).to eq(:fits)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # evaluate_dimensions — embedding dimensions (step 6)
  # ---------------------------------------------------------------------------

  describe '#evaluate_dimensions' do
    context 'when no dimensions are requested' do
      it 'returns :not_applicable' do
        lane = lane_double(embedding_dimensions_evidence: known_evidence([1536]))
        expect(filter.evaluate_dimensions(lane: lane, requested_dimensions: nil)).to eq(:not_applicable)
      end
    end

    context 'when requested dimensions match authoritative evidence' do
      it 'returns :match' do
        lane = lane_double(embedding_dimensions_evidence: known_evidence([768, 1536]))
        expect(filter.evaluate_dimensions(lane: lane, requested_dimensions: 1536)).to eq(:match)
      end
    end

    context 'when requested dimensions do not match authoritative evidence' do
      it 'returns :rejected' do
        lane = lane_double(embedding_dimensions_evidence: known_evidence([768]))
        expect(filter.evaluate_dimensions(lane: lane, requested_dimensions: 1536)).to eq(:rejected)
      end
    end

    context 'when dimension evidence is unknown' do
      it 'returns :unknown' do
        lane = lane_double(embedding_dimensions_evidence: unknown_evidence)
        expect(filter.evaluate_dimensions(lane: lane, requested_dimensions: 1536)).to eq(:unknown)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # filter_exclusions — typed exclusions (step 8)
  # ---------------------------------------------------------------------------

  describe '#filter_exclusions' do
    let(:ik) { instance_key_double(provider_family: :vllm, instance_id: 'h200') }
    let(:lane) do
      lane_double(
        instance_key: ik,
        model:        'gemma4',
        lane_id:      'direct:vllm:h200:inference:gemma4',
        quota_domain: nil
      )
    end

    context 'when exclusions list is empty' do
      it 'returns :clear' do
        expect(filter.filter_exclusions(lane: lane, exclusions: [])).to eq(:clear)
      end
    end

    context 'attempt_target exclusion' do
      it 'returns :excluded when provider_family, instance_id, and model all match' do
        target = double('AttemptTargetKey', provider_family: :vllm, instance_id: 'h200', model: 'gemma4')
        excl = exclusion_double(target_kind: :attempt_target, target: target)
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:excluded)
      end

      it 'returns :clear when model does not match' do
        target = double('AttemptTargetKey', provider_family: :vllm, instance_id: 'h200', model: 'llama3')
        excl = exclusion_double(target_kind: :attempt_target, target: target)
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:clear)
      end

      it 'returns :clear when instance_id does not match' do
        target = double('AttemptTargetKey', provider_family: :vllm, instance_id: 'other', model: 'gemma4')
        excl = exclusion_double(target_kind: :attempt_target, target: target)
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:clear)
      end
    end

    context 'instance exclusion' do
      it 'returns :excluded when instance_key matches' do
        excl = exclusion_double(target_kind: :instance, target: ik)
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:excluded)
      end

      it 'returns :clear when instance_key does not match' do
        other_ik = instance_key_double(provider_family: :vllm, instance_id: 'other')
        excl = exclusion_double(target_kind: :instance, target: other_ik)
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:clear)
      end
    end

    context 'lane exclusion' do
      it 'returns :excluded when lane_id matches' do
        excl = exclusion_double(target_kind: :lane, target: 'direct:vllm:h200:inference:gemma4')
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:excluded)
      end

      it 'returns :clear when lane_id does not match' do
        excl = exclusion_double(target_kind: :lane, target: 'direct:vllm:h200:inference:llama3')
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:clear)
      end
    end

    context 'offering exclusion' do
      it 'returns :excluded when lane_id matches (offering uses lane_id)' do
        excl = exclusion_double(target_kind: :offering, target: 'direct:vllm:h200:inference:gemma4')
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:excluded)
      end
    end

    context 'model exclusion' do
      it 'returns :excluded when model matches' do
        excl = exclusion_double(target_kind: :model, target: 'gemma4')
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:excluded)
      end

      it 'returns :clear when model does not match' do
        excl = exclusion_double(target_kind: :model, target: 'llama3')
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:clear)
      end
    end

    context 'provider exclusion' do
      it 'returns :excluded when provider_family matches' do
        excl = exclusion_double(target_kind: :provider, target: :vllm)
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:excluded)
      end

      it 'returns :clear when provider_family does not match' do
        excl = exclusion_double(target_kind: :provider, target: :anthropic)
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:clear)
      end
    end

    context 'quota_domain exclusion' do
      it 'returns :excluded when quota_domain matches' do
        lane_with_qd = lane_double(
          instance_key: ik, model: 'gemma4',
          lane_id: 'direct:vllm:h200:inference:gemma4',
          quota_domain: 'my-quota'
        )
        excl = exclusion_double(target_kind: :quota_domain, target: 'my-quota')
        expect(filter.filter_exclusions(lane: lane_with_qd, exclusions: [excl])).to eq(:excluded)
      end

      it 'returns :clear when quota_domain is nil on the lane' do
        excl = exclusion_double(target_kind: :quota_domain, target: 'my-quota')
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:clear)
      end

      it 'returns :clear when quota_domain does not match' do
        lane_with_qd = lane_double(
          instance_key: ik, model: 'gemma4',
          lane_id: 'direct:vllm:h200:inference:gemma4',
          quota_domain: 'other-quota'
        )
        excl = exclusion_double(target_kind: :quota_domain, target: 'my-quota')
        expect(filter.filter_exclusions(lane: lane_with_qd, exclusions: [excl])).to eq(:clear)
      end
    end

    context 'unknown target_kind' do
      it 'returns :clear (does not match)' do
        excl = exclusion_double(target_kind: :unknown_kind, target: 'anything')
        expect(filter.filter_exclusions(lane: lane, exclusions: [excl])).to eq(:clear)
      end
    end

    context 'multiple exclusions' do
      it 'returns :excluded if any one matches' do
        non_match = exclusion_double(target_kind: :model, target: 'llama3')
        match = exclusion_double(target_kind: :model, target: 'gemma4')
        expect(filter.filter_exclusions(lane: lane, exclusions: [non_match, match])).to eq(:excluded)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # model_policy_for — 3-scope specificity cascade
  # ---------------------------------------------------------------------------

  describe '#model_policy_for' do
    before do
      Legion::Settings.loader.settings[:extensions] ||= {}
      Legion::Settings.loader.settings[:extensions][:llm] ||= {}
    end

    let(:ik) { instance_key_double(provider_family: :vllm, instance_id: 'h200') }
    let(:lane) { lane_double(instance_key: ik, model: 'gemma4') }

    context 'when nothing is configured' do
      it 'returns empty whitelist and blacklist' do
        policy = filter.model_policy_for(lane: lane)
        expect(policy[:whitelist]).to eq([])
        expect(policy[:blacklist]).to eq([])
      end

      it 'returns a frozen hash' do
        expect(filter.model_policy_for(lane: lane)).to be_frozen
      end
    end

    context 'instance-level policy (most specific wins)' do
      before do
        Legion::Settings.loader.settings[:extensions][:llm][:vllm] = {
          model_whitelist: %w[global-allowed],
          instances:       { h200: { model_whitelist: %w[instance-allowed] } }
        }
      end

      it 'uses the instance-level whitelist' do
        policy = filter.model_policy_for(lane: lane)
        expect(policy[:whitelist]).to eq(%w[instance-allowed])
      end
    end

    context 'falls through to provider-level when instance key is absent' do
      before do
        Legion::Settings.loader.settings[:extensions][:llm][:vllm] = {
          model_whitelist: %w[provider-allowed],
          instances:       { h200: { weight: 1 } }
        }
      end

      it 'uses the provider-level whitelist' do
        policy = filter.model_policy_for(lane: lane)
        expect(policy[:whitelist]).to eq(%w[provider-allowed])
      end
    end

    context 'falls through to global when provider and instance lack the key' do
      before do
        Legion::Settings.loader.settings[:extensions][:llm].merge!(
          model_whitelist: %w[global-allowed],
          vllm:            { weight: 1 }
        )
      end

      it 'uses the global-level whitelist' do
        policy = filter.model_policy_for(lane: lane)
        expect(policy[:whitelist]).to eq(%w[global-allowed])
      end
    end

    context 'explicit empty array at instance beats provider nonempty list' do
      before do
        Legion::Settings.loader.settings[:extensions][:llm][:vllm] = {
          model_whitelist: %w[provider-allowed],
          instances:       { h200: { model_whitelist: [] } }
        }
      end

      it 'uses the explicit empty array from instance level' do
        policy = filter.model_policy_for(lane: lane)
        expect(policy[:whitelist]).to eq([])
      end
    end

    context 'blacklist resolves independently from whitelist' do
      before do
        Legion::Settings.loader.settings[:extensions][:llm][:vllm] = {
          model_blacklist: %w[provider-denied],
          instances:       { h200: { model_whitelist: %w[instance-allowed] } }
        }
      end

      it 'resolves each list from its own cascade position' do
        policy = filter.model_policy_for(lane: lane)
        expect(policy[:whitelist]).to eq(%w[instance-allowed])
        expect(policy[:blacklist]).to eq(%w[provider-denied])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # preferred_context_range_for — SettingsCascade resolution
  # ---------------------------------------------------------------------------

  describe '#preferred_context_range_for' do
    before do
      Legion::Settings.loader.settings[:extensions] ||= {}
      Legion::Settings.loader.settings[:extensions][:llm] ||= {}
    end

    let(:ik) { instance_key_double(provider_family: :vllm, instance_id: 'h200') }
    let(:lane) { lane_double(instance_key: ik, model: 'gemma4') }

    context 'when no preferred range is configured' do
      it 'returns nil' do
        expect(filter.preferred_context_range_for(lane: lane)).to be_nil
      end
    end

    context 'when both min and max are configured at instance level' do
      before do
        Legion::Settings.loader.settings[:extensions][:llm][:vllm] = {
          instances: { 'h200' => { preferred_min_context_tokens: 1024, preferred_max_context_tokens: 8192 } }
        }
      end

      it 'returns the configured range' do
        range = filter.preferred_context_range_for(lane: lane)
        expect(range).to eq({ min: 1024, max: 8192 })
      end

      it 'returns a frozen hash' do
        expect(filter.preferred_context_range_for(lane: lane)).to be_frozen
      end
    end

    context 'when only max is configured at provider level' do
      before do
        Legion::Settings.loader.settings[:extensions][:llm][:vllm] = {
          preferred_max_context_tokens: 8192
        }
      end

      it 'returns min: nil, max: configured' do
        range = filter.preferred_context_range_for(lane: lane)
        expect(range).to eq({ min: nil, max: 8192 })
      end
    end

    context 'when model-level override beats instance-level' do
      before do
        Legion::Settings.loader.settings[:extensions][:llm][:vllm] = {
          instances: {
            'h200' => {
              preferred_min_context_tokens: 1024,
              models:                       { 'gemma4' => { preferred_min_context_tokens: 2048 } }
            }
          }
        }
      end

      it 'uses the model-level value (most-specific-first)' do
        range = filter.preferred_context_range_for(lane: lane)
        expect(range).to eq({ min: 2048, max: nil })
      end
    end

    context 'when instance min is merged with provider max (per-key cascade)' do
      before do
        Legion::Settings.loader.settings[:extensions][:llm][:vllm] = {
          preferred_max_context_tokens: 8192,
          instances:                    { 'h200' => { preferred_min_context_tokens: 1024 } }
        }
      end

      it 'resolves min from instance and max from provider' do
        range = filter.preferred_context_range_for(lane: lane)
        expect(range).to eq({ min: 1024, max: 8192 })
      end
    end
  end

  # ---------------------------------------------------------------------------
  # body_model_hint_decision — the 7 dispositions
  # ---------------------------------------------------------------------------

  describe '#body_model_hint_decision_for' do
    before do
      Legion::Settings.loader.settings[:llm] ||= {}
      Legion::Settings.loader.settings[:llm][:router] ||= {}
      Legion::Settings.loader.settings[:llm][:router].merge!(
        allow_body_routing_hints:   true,
        body_model_hint_whitelist:  [],
        body_model_hint_blacklist:  [],
        auto_routing_model_aliases: %w[legionio auto copilot-utility-small]
      )
    end

    # Disposition 1: absent
    context 'when body_model is nil' do
      it 'returns disposition :absent with nil requested_model' do
        d = filter.body_model_hint_decision_for(body_model: nil, trusted_model: nil)
        expect(d.disposition).to eq(:absent)
        expect(d.requested_model).to be_nil
        expect(d.model_constraint).to be_nil
      end
    end

    context 'when body_model is blank' do
      it 'returns disposition :absent' do
        d = filter.body_model_hint_decision_for(body_model: '   ', trusted_model: nil)
        expect(d.disposition).to eq(:absent)
        expect(d.requested_model).to be_nil
      end
    end

    context 'when body_model is an empty string' do
      it 'returns disposition :absent' do
        d = filter.body_model_hint_decision_for(body_model: '', trusted_model: nil)
        expect(d.disposition).to eq(:absent)
      end
    end

    # Disposition 2: superseded_by_explicit_model
    context 'when both body_model and trusted_model are present' do
      it 'returns disposition :superseded_by_explicit_model' do
        d = filter.body_model_hint_decision_for(body_model: 'claude-haiku', trusted_model: 'gpt-5')
        expect(d.disposition).to eq(:superseded_by_explicit_model)
        expect(d.model_constraint).to be_nil
        expect(d.requested_model).to eq('claude-haiku')
      end
    end

    # Disposition 3: auto (auto-routing alias)
    context 'when body_model is an auto-routing alias' do
      it 'returns disposition :auto for "legionio"' do
        d = filter.body_model_hint_decision_for(body_model: 'legionio', trusted_model: nil)
        expect(d.disposition).to eq(:auto)
        expect(d.model_constraint).to be_nil
      end

      it 'returns disposition :auto for "auto"' do
        d = filter.body_model_hint_decision_for(body_model: 'auto', trusted_model: nil)
        expect(d.disposition).to eq(:auto)
      end

      it 'returns disposition :auto for "copilot-utility-small"' do
        d = filter.body_model_hint_decision_for(body_model: 'copilot-utility-small', trusted_model: nil)
        expect(d.disposition).to eq(:auto)
      end

      it 'is case-insensitive' do
        d = filter.body_model_hint_decision_for(body_model: 'LEGIONIO', trusted_model: nil)
        expect(d.disposition).to eq(:auto)
      end
    end

    # Disposition 4: ignored_disabled
    context 'when allow_body_routing_hints is false' do
      before do
        Legion::Settings.loader.settings[:llm][:router][:allow_body_routing_hints] = false
      end

      it 'returns disposition :ignored_disabled' do
        d = filter.body_model_hint_decision_for(body_model: 'claude-haiku', trusted_model: nil)
        expect(d.disposition).to eq(:ignored_disabled)
        expect(d.model_constraint).to be_nil
      end
    end

    # Disposition 5: ignored_not_whitelisted
    context 'when whitelist is non-empty and model does not match' do
      before do
        Legion::Settings.loader.settings[:llm][:router][:body_model_hint_whitelist] = %w[qwen]
      end

      it 'returns disposition :ignored_not_whitelisted' do
        d = filter.body_model_hint_decision_for(body_model: 'claude-haiku', trusted_model: nil)
        expect(d.disposition).to eq(:ignored_not_whitelisted)
      end
    end

    context 'when whitelist matches (case-insensitive substring)' do
      before do
        Legion::Settings.loader.settings[:llm][:router][:body_model_hint_whitelist] = %w[qwen]
      end

      it 'returns disposition :honored' do
        d = filter.body_model_hint_decision_for(body_model: 'QWEN-32B', trusted_model: nil)
        expect(d.disposition).to eq(:honored)
        expect(d.matched_whitelist).to eq('qwen')
      end
    end

    # Disposition 6: ignored_blacklisted
    context 'when blacklist matches' do
      before do
        Legion::Settings.loader.settings[:llm][:router][:body_model_hint_blacklist] = %w[haiku]
      end

      it 'returns disposition :ignored_blacklisted' do
        d = filter.body_model_hint_decision_for(body_model: 'claude-3-5-haiku-20241022', trusted_model: nil)
        expect(d.disposition).to eq(:ignored_blacklisted)
        expect(d.matched_blacklist).to eq('haiku')
      end
    end

    context 'when blacklist wins even when whitelist also matches' do
      before do
        Legion::Settings.loader.settings[:llm][:router][:body_model_hint_whitelist] = %w[claude]
        Legion::Settings.loader.settings[:llm][:router][:body_model_hint_blacklist] = %w[haiku]
      end

      it 'returns disposition :ignored_blacklisted' do
        d = filter.body_model_hint_decision_for(body_model: 'claude-haiku', trusted_model: nil)
        expect(d.disposition).to eq(:ignored_blacklisted)
        expect(d.matched_blacklist).to eq('haiku')
        expect(d.matched_whitelist).to eq('claude')
      end
    end

    # Disposition 7: honored
    context 'when body_model passes all checks' do
      it 'returns disposition :honored with model_constraint set' do
        d = filter.body_model_hint_decision_for(body_model: 'gemma4', trusted_model: nil)
        expect(d.disposition).to eq(:honored)
        expect(d.model_constraint).to eq('gemma4')
      end
    end

    context 'when whitelist is empty and blacklist is empty' do
      it 'honors any non-auto model' do
        d = filter.body_model_hint_decision_for(body_model: 'gpt-5-turbo', trusted_model: nil)
        expect(d.disposition).to eq(:honored)
        expect(d.model_constraint).to eq('gpt-5-turbo')
      end
    end

    # settings_generation is always 0 (the mixin passes a literal 0)
    it 'always returns settings_generation 0' do
      d = filter.body_model_hint_decision_for(body_model: 'gemma4', trusted_model: nil)
      expect(d.settings_generation).to eq(0)
    end

    # Normalization: whitespace trimming
    it 'trims whitespace from body_model' do
      d = filter.body_model_hint_decision_for(body_model: '  gemma4  ', trusted_model: nil)
      expect(d.disposition).to eq(:honored)
      expect(d.model_constraint).to eq('gemma4')
    end

    # Ladder order: auto alias check happens BEFORE disabled check
    context 'auto alias with hints disabled' do
      before do
        Legion::Settings.loader.settings[:llm][:router][:allow_body_routing_hints] = false
      end

      it 'still returns :auto (alias check precedes disabled check)' do
        d = filter.body_model_hint_decision_for(body_model: 'legionio', trusted_model: nil)
        expect(d.disposition).to eq(:auto)
      end
    end

    # Ladder order: trusted_model supersedes even when model is an alias
    context 'auto alias with trusted_model present' do
      it 'returns :superseded_by_explicit_model (trusted wins over alias)' do
        d = filter.body_model_hint_decision_for(body_model: 'legionio', trusted_model: 'claude-3')
        expect(d.disposition).to eq(:superseded_by_explicit_model)
      end
    end
  end
end
