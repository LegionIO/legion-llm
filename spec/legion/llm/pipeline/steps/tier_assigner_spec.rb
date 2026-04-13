# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::TierAssigner do
  subject(:assigner) { described_class }

  describe '.assign' do
    context 'when explicit tier already set by caller' do
      it 'returns nil without overriding' do
        result = assigner.assign(
          caller:          { requested_by: { identity: 'user:matt', type: :user } },
          classification:  nil,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   :cloud,
          existing_intent: nil
        )
        expect(result).to be_nil
      end
    end

    context 'when GAIA routing hint is present' do
      it 'assigns tier from GAIA recommended_tier' do
        gaia_hint = { data: { recommended_tier: 'local' }, timestamp: Time.now }
        result = assigner.assign(
          caller:          nil,
          classification:  nil,
          priority:        :normal,
          gaia_hint:       gaia_hint,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:local)
        expect(result[:source]).to eq(:gaia)
      end

      it 'converts string recommended_tier to symbol' do
        gaia_hint = { data: { recommended_tier: 'cloud' }, timestamp: Time.now }
        result = assigner.assign(
          caller: nil, classification: nil, priority: :normal,
          gaia_hint: gaia_hint, existing_tier: nil, existing_intent: nil
        )
        expect(result[:tier]).to eq(:cloud)
      end

      it 'skips GAIA hint when recommended_tier is absent' do
        gaia_hint = { data: { other_key: 'value' }, timestamp: Time.now }
        result = assigner.assign(
          caller:          { requested_by: { identity: 'system:guardrails', type: :system } },
          classification:  nil,
          priority:        :normal,
          gaia_hint:       gaia_hint,
          existing_tier:   nil,
          existing_intent: nil
        )
        # Falls through to role mapping
        expect(result[:source]).to eq(:role_mapping)
      end
    end

    context 'role mapping from caller identity' do
      before do
        Legion::Settings[:llm][:routing][:tier_mappings] = []
      end

      it 'routes gaia:tick:* callers to local tier' do
        result = assigner.assign(
          caller:          { requested_by: { identity: 'gaia:tick:phase_3', type: :system } },
          classification:  nil,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:local)
        expect(result[:intent]).to include(cost: :minimize)
        expect(result[:source]).to eq(:role_mapping)
      end

      it 'routes gaia:dream:* callers to local tier' do
        result = assigner.assign(
          caller:          { requested_by: { identity: 'gaia:dream:phase_17', type: :system } },
          classification:  nil,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:local)
        expect(result[:source]).to eq(:role_mapping)
      end

      it 'routes system:guardrails to local with basic capability' do
        result = assigner.assign(
          caller:          { requested_by: { identity: 'system:guardrails', type: :system } },
          classification:  nil,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:local)
        expect(result[:intent]).to include(capability: :basic)
        expect(result[:source]).to eq(:role_mapping)
      end

      it 'routes system:reflection to local with moderate capability' do
        result = assigner.assign(
          caller:          { requested_by: { identity: 'system:reflection', type: :system } },
          classification:  nil,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:local)
        expect(result[:intent]).to include(capability: :moderate)
        expect(result[:source]).to eq(:role_mapping)
      end

      it 'routes user:* callers to cloud with reasoning capability' do
        result = assigner.assign(
          caller:          { requested_by: { identity: 'user:alice', type: :user } },
          classification:  nil,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:cloud)
        expect(result[:intent]).to include(capability: :reasoning)
        expect(result[:source]).to eq(:role_mapping)
      end

      it 'returns nil when identity does not match any pattern' do
        result = assigner.assign(
          caller:          { requested_by: { identity: 'unknown:service', type: :system } },
          classification:  nil,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result).to be_nil
      end

      it 'returns nil when caller is nil' do
        result = assigner.assign(
          caller:          nil,
          classification:  nil,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result).to be_nil
      end
    end

    context 'settings-driven role mappings' do
      it 'uses custom tier_mappings from settings when present' do
        Legion::Settings[:llm][:routing][:tier_mappings] = [
          { pattern: 'custom:worker:*', tier: :fleet, intent: { cost: :minimize } }
        ]
        result = assigner.assign(
          caller:          { requested_by: { identity: 'custom:worker:job1', type: :system } },
          classification:  nil,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:fleet)
        expect(result[:source]).to eq(:role_mapping)
      end
    end

    context 'classification-driven tier assignment (PHI/PII hard gate — fail closed)' do
      it 'constrains PHI to local tier, never cloud' do
        classification = { contains_phi: true, contains_pii: false }
        result = assigner.assign(
          caller:          nil,
          classification:  classification,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:local)
        expect(result[:tier]).not_to eq(:cloud)
        expect(result[:intent]).to include(privacy: :strict)
        expect(result[:source]).to eq(:classification)
      end

      it 'constrains PII to local tier, never cloud' do
        classification = { contains_phi: false, contains_pii: true }
        result = assigner.assign(
          caller:          nil,
          classification:  classification,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:local)
        expect(result[:tier]).not_to eq(:cloud)
        expect(result[:source]).to eq(:classification)
      end

      it 'constrains restricted classification level to local tier' do
        result = assigner.assign(
          caller:          nil,
          classification:  { level: :restricted },
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:local)
        expect(result[:source]).to eq(:classification)
      end

      it 'returns nil when classification is normal (no PHI/PII/restricted)' do
        classification = { contains_phi: false, contains_pii: false, level: :normal }
        result = assigner.assign(
          caller:          nil,
          classification:  classification,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result).to be_nil
      end
    end

    context 'priority-driven tier assignment' do
      it 'routes critical priority to cloud with reasoning' do
        result = assigner.assign(
          caller:          nil,
          classification:  nil,
          priority:        :critical,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:cloud)
        expect(result[:intent]).to include(capability: :reasoning)
        expect(result[:source]).to eq(:priority)
      end

      it 'routes high priority to cloud with reasoning' do
        result = assigner.assign(
          caller:          nil,
          classification:  nil,
          priority:        :high,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:cloud)
        expect(result[:source]).to eq(:priority)
      end

      it 'routes low priority to local with minimize cost' do
        result = assigner.assign(
          caller:          nil,
          classification:  nil,
          priority:        :low,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:local)
        expect(result[:intent]).to include(cost: :minimize)
        expect(result[:source]).to eq(:priority)
      end

      it 'routes background priority to local with minimize cost' do
        result = assigner.assign(
          caller:          nil,
          classification:  nil,
          priority:        :background,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:local)
        expect(result[:source]).to eq(:priority)
      end

      it 'returns nil for normal priority with no other signals' do
        result = assigner.assign(
          caller:          nil,
          classification:  nil,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result).to be_nil
      end
    end

    context 'priority order: GAIA hint wins over role mapping' do
      it 'prefers GAIA hint over role mapping when both present' do
        gaia_hint = { data: { recommended_tier: 'fleet' }, timestamp: Time.now }
        result = assigner.assign(
          caller:          { requested_by: { identity: 'user:alice', type: :user } },
          classification:  nil,
          priority:        :normal,
          gaia_hint:       gaia_hint,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:tier]).to eq(:fleet)
        expect(result[:source]).to eq(:gaia)
      end

      it 'prefers role mapping over classification' do
        classification = { contains_phi: true, contains_pii: false }
        result = assigner.assign(
          caller:          { requested_by: { identity: 'gaia:tick:phase_1', type: :system } },
          classification:  classification,
          priority:        :normal,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:source]).to eq(:role_mapping)
        expect(result[:tier]).to eq(:local)
      end

      it 'prefers classification over priority (PHI overrides low priority → local)' do
        classification = { contains_phi: true, contains_pii: false }
        result = assigner.assign(
          caller:          nil,
          classification:  classification,
          priority:        :low,
          gaia_hint:       nil,
          existing_tier:   nil,
          existing_intent: nil
        )
        expect(result[:source]).to eq(:classification)
        expect(result[:tier]).to eq(:local)
      end
    end
  end

  describe '.find_role_mapping' do
    it 'returns nil when caller is nil' do
      expect(assigner.find_role_mapping(nil)).to be_nil
    end

    it 'returns nil when identity is missing' do
      expect(assigner.find_role_mapping({ requested_by: {} })).to be_nil
    end

    it 'matches exact identity strings' do
      result = assigner.find_role_mapping(
        { requested_by: { identity: 'system:guardrails' } }
      )
      expect(result).not_to be_nil
      expect(result[:tier]).to eq(:local)
    end
  end

  describe '.tier_mappings' do
    it 'returns default mappings when settings tier_mappings is empty' do
      Legion::Settings[:llm][:routing][:tier_mappings] = []
      mappings = assigner.tier_mappings
      expect(mappings).to eq(described_class::DEFAULT_MAPPINGS)
    end

    it 'returns settings mappings when configured' do
      custom = [{ pattern: 'x:*', tier: :fleet, intent: {} }]
      Legion::Settings[:llm][:routing][:tier_mappings] = custom
      expect(assigner.tier_mappings).to eq(custom)
    end

    it 'falls back to DEFAULT_MAPPINGS when settings key is absent' do
      Legion::Settings[:llm][:routing].delete(:tier_mappings)
      expect(assigner.tier_mappings).to eq(described_class::DEFAULT_MAPPINGS)
    end
  end
end
