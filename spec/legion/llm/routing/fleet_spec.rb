# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/routing/fleet'

RSpec.describe Legion::LLM::Routing::Fleet, ssot_v3: true do
  let(:fleet_obj) do
    Class.new do
      include Legion::LLM::Routing::Fleet
    end.new
  end

  before do
    Legion::Settings.loader.settings[:llm] ||= {}
    Legion::Settings.loader.settings[:llm][:router] ||= {}
  end

  describe '#fleet_enabled?' do
    context 'when fleet_dispatch_enabled is not set' do
      before do
        Legion::Settings.loader.settings[:llm][:router].delete(:fleet_dispatch_enabled)
      end

      it 'returns true (default-on)' do
        expect(fleet_obj.fleet_enabled?).to be true
      end
    end

    context 'when fleet_dispatch_enabled is true' do
      before do
        Legion::Settings.loader.settings[:llm][:router][:fleet_dispatch_enabled] = true
      end

      it 'returns true' do
        expect(fleet_obj.fleet_enabled?).to be true
      end
    end

    context 'when fleet_dispatch_enabled is explicitly false' do
      before do
        Legion::Settings.loader.settings[:llm][:router][:fleet_dispatch_enabled] = false
      end

      it 'returns false' do
        expect(fleet_obj.fleet_enabled?).to be false
      end
    end
  end

  describe '#fleet_lane?' do
    context 'with a fleet-tier lane carrying exact_offering_v1 contract' do
      before do
        activate(
          provider_family: :test_fleet, instance_id: 'fleet-1',
          drafts: [offering_draft(
            model: 'fleet-model-a', tier: :fleet,
            metadata: { fleet_execution_contract: 'exact_offering_v1' }
          )]
        )
      end

      it 'returns true' do
        snap = snapshot
        lane = snap.each_lane.find { |l| l.tier == :fleet && l.model == 'fleet-model-a' }
        expect(fleet_obj.fleet_lane?(lane: lane)).to be true
      end
    end

    context 'with a non-fleet tier lane' do
      before do
        activate(
          provider_family: :test_local, instance_id: 'local-1',
          drafts: [offering_draft(model: 'local-model-a', tier: :local)]
        )
      end

      it 'returns false' do
        snap = snapshot
        lane = snap.each_lane.find { |l| l.tier == :local && l.model == 'local-model-a' }
        expect(fleet_obj.fleet_lane?(lane: lane)).to be false
      end
    end

    context 'with a fleet-tier lane missing the contract (legacy)' do
      before do
        activate(
          provider_family: :test_fleet_legacy, instance_id: 'fleet-2',
          drafts: [offering_draft(
            model: 'fleet-model-legacy', tier: :fleet,
            metadata: {}
          )]
        )
      end

      it 'returns false (missing contract)' do
        snap = snapshot
        lane = snap.each_lane.find { |l| l.tier == :fleet && l.model == 'fleet-model-legacy' }
        expect(fleet_obj.fleet_lane?(lane: lane)).to be false
      end
    end

    context 'with a fleet-tier lane carrying an unknown contract' do
      before do
        activate(
          provider_family: :test_fleet_unknown, instance_id: 'fleet-3',
          drafts: [offering_draft(
            model: 'fleet-model-unknown', tier: :fleet,
            metadata: { fleet_execution_contract: 'future_contract_v99' }
          )]
        )
      end

      it 'returns false (unrecognized contract)' do
        snap = snapshot
        lane = snap.each_lane.find { |l| l.tier == :fleet && l.model == 'fleet-model-unknown' }
        expect(fleet_obj.fleet_lane?(lane: lane)).to be false
      end
    end
  end
end
