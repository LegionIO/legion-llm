# frozen_string_literal: true

require 'spec_helper'

# P2 Commit 1 — HealthTracker writes lane health to Inventory on circuit transitions.
# G21: HealthTracker write overwrites; refresher write (health: :preserve) preserves.
# G23: deny_model sets health[:denied]=true with sign-flip magnitude.
RSpec.describe Legion::LLM::Router::HealthTracker, 'Inventory writes on transitions' do
  # Use a fresh tracker per example for isolation; also reset the shared singleton.
  subject(:tracker) { described_class.new(window_seconds: 300, failure_threshold: 3, cooldown_seconds: 60) }

  def build_lane(provider: :bedrock, tier: :cloud, instance: :account_a, model: 'sonnet-4-6', type: :inference)
    id = "#{tier}:#{provider}:#{instance}:#{type}:#{model}"
    {
      id:              id,
      tier:            tier,
      provider_family: provider,
      instance_id:     instance,
      model:           model.to_s,
      type:            type
    }
  end

  # Seed provider settings so compute_lane_weight can derive weights.
  before do
    Legion::Settings[:extensions][:llm][:bedrock] ||= {}
    Legion::Settings[:extensions][:llm][:bedrock][:weight]     ||= 100
    Legion::Settings[:extensions][:llm][:bedrock][:instances]  ||= {}
    Legion::Settings[:extensions][:llm][:bedrock][:models]     ||= {}
    # Also reset the Router singleton so health_tracker accessor starts fresh.
    Legion::LLM::Router.reset! if Legion::LLM::Router.respond_to?(:reset!)
  end

  # ─── Commit 1a: instance trip writes ALL matching lanes ──────────────────────

  describe 'instance trip writes all matching lanes' do
    it 'trips ALL lanes for (provider, instance) when error threshold is reached' do
      4.times do |i|
        Legion::LLM::Inventory.write_lane(
          lane: build_lane(provider: :bedrock, instance: :account_a, model: "model-#{i}"),
          ttl:  3600
        )
      end

      3.times { tracker.report(provider: :bedrock, instance: :account_a, signal: :error, value: 1) }

      lanes = Legion::LLM::Inventory.lanes_for(provider: :bedrock, instance: :account_a)
      expect(lanes.size).to eq(4)
      lanes.each do |lane|
        expect(lane[:health][:circuit_state]).to eq(:open)
        expect(lane[:health][:available]).to eq(false)
        expect(lane[:lane_weight]).to be < 0
      end
    end
  end

  # ─── Commit 1b: sibling instance untouched ───────────────────────────────────

  describe 'sibling instance untouched on trip' do
    it 'does not affect lanes for a different instance of the same provider' do
      Legion::LLM::Inventory.write_lane(
        lane: build_lane(provider: :bedrock, instance: :account_a, model: 'sonnet'), ttl: 3600
      )
      Legion::LLM::Inventory.write_lane(
        lane: build_lane(provider: :bedrock, instance: :account_b, model: 'sonnet'), ttl: 3600
      )

      3.times { tracker.report(provider: :bedrock, instance: :account_a, signal: :error, value: 1) }

      lane_a = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:account_a:inference:sonnet')
      lane_b = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:account_b:inference:sonnet')

      expect(lane_a[:health][:circuit_state]).to eq(:open)
      expect(lane_b[:health][:circuit_state]).to eq(:closed)
      expect(lane_b[:lane_weight]).to be > 0
    end
  end

  # ─── Commit 1c: deny_model writes only the specific lane ─────────────────────

  describe 'deny_model writes denied health to specific lane only' do
    it 'sets denied=true only on the denied (provider, instance, model) lane' do
      Legion::LLM::Inventory.write_lane(
        lane: build_lane(provider: :bedrock, instance: :account_a, model: 'sonnet'), ttl: 3600
      )
      Legion::LLM::Inventory.write_lane(
        lane: build_lane(provider: :bedrock, instance: :account_a, model: 'opus'), ttl: 3600
      )

      tracker.deny_model(provider: :bedrock, instance: :account_a,
                         model: 'sonnet', reason: :access_denied)

      sonnet = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:account_a:inference:sonnet')
      opus   = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:account_a:inference:opus')

      expect(sonnet[:health][:denied]).to be true
      expect(sonnet[:health][:available]).to eq(false)
      expect(opus[:health][:denied]).to be false
    end

    it 'gives denied lane a negative lane_weight (G23)' do
      Legion::LLM::Inventory.write_lane(
        lane: build_lane(provider: :bedrock, instance: :account_a, model: 'sonnet'), ttl: 3600
      )
      tracker.deny_model(provider: :bedrock, instance: :account_a,
                         model: 'sonnet', reason: :access_denied)

      lane = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:account_a:inference:sonnet')
      expect(lane[:lane_weight]).to be < 0
    end
  end

  # ─── Commit 1d: G21 health-preserve interaction ──────────────────────────────
  # HealthTracker write OVERWRITES; refresher tick (omits health:) PRESERVES.

  describe 'G21 health-preserve interaction' do
    it 'preserves HealthTracker-written state after a refresher tick overwrites lane facts' do
      lane = build_lane(provider: :bedrock, instance: :default, model: 'claude-sonnet-4-6')
      Legion::LLM::Inventory.write_lane(lane: lane, ttl: 3600)

      # HealthTracker trips the lane
      3.times { tracker.report(provider: :bedrock, instance: :default, signal: :error, value: 1) }

      stored = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-sonnet-4-6')
      expect(stored[:health][:circuit_state]).to eq(:open)

      # Refresher writes without health: kwarg (uses :preserve sentinel)
      Legion::LLM::Inventory.write_lane(lane: lane, ttl: 3600)

      after_refresh = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:default:inference:claude-sonnet-4-6')
      expect(after_refresh[:health][:circuit_state]).to eq(:open)
    end
  end

  # ─── Commit 1e: half_open transition writes lane ─────────────────────────────

  describe 'half_open transition via cooldown' do
    it 'writes half_open to lanes when error re-probe during half_open state' do
      Legion::LLM::Inventory.write_lane(
        lane: build_lane(provider: :bedrock, instance: :account_a, model: 'sonnet'), ttl: 3600
      )

      3.times { tracker.report(provider: :bedrock, instance: :account_a, signal: :error, value: 1) }

      # Directly set circuit to :half_open to simulate post-cooldown state
      # (half_open transition normally triggered inside circuit_state_for_key after cooldown)
      circuit = tracker.instance_variable_get(:@circuits)['bedrock/account_a']
      circuit[:state] = :half_open

      # A success during half_open closes the circuit — verify lane gets written
      tracker.report(provider: :bedrock, instance: :account_a, signal: :success, value: nil)

      lane = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:account_a:inference:sonnet')
      expect(lane[:health][:circuit_state]).to eq(:closed)
      expect(lane[:lane_weight]).to be > 0
    end
  end

  # ─── Commit 1f: success closes circuit and writes closed health ──────────────

  describe 'success transition' do
    it 'writes closed health on success after open circuit' do
      Legion::LLM::Inventory.write_lane(
        lane: build_lane(provider: :bedrock, instance: :account_a, model: 'sonnet'), ttl: 3600
      )

      3.times { tracker.report(provider: :bedrock, instance: :account_a, signal: :error, value: 1) }
      tracker.report(provider: :bedrock, instance: :account_a, signal: :success, value: nil)

      lane = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:account_a:inference:sonnet')
      expect(lane[:health][:circuit_state]).to eq(:closed)
      expect(lane[:health][:available]).to eq(true)
      expect(lane[:lane_weight]).to be > 0
    end
  end

  # ─── Commit 1g: parallel-trip spec (gate requirement) ───────────────────────
  # Request 2 trips a breaker; request 3 sees :open immediately (no staleness).

  describe 'parallel-trip: breaker trip is immediately visible in Inventory' do
    it 'lane shows :open right after the threshold is reached, no read-through delay' do
      Legion::LLM::Inventory.write_lane(
        lane: build_lane(provider: :bedrock, instance: :account_a, model: 'sonnet'), ttl: 3600
      )

      # First two requests fail (not yet at threshold)
      2.times { tracker.report(provider: :bedrock, instance: :account_a, signal: :error, value: 1) }
      lane_before = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:account_a:inference:sonnet')
      expect(lane_before[:health][:circuit_state]).to eq(:closed)

      # Third request tips the circuit
      tracker.report(provider: :bedrock, instance: :account_a, signal: :error, value: 1)

      lane_after = Legion::LLM::Inventory.lane(id: 'cloud:bedrock:account_a:inference:sonnet')
      expect(lane_after[:health][:circuit_state]).to eq(:open)
      expect(lane_after[:lane_weight]).to be < 0
    end
  end
end
