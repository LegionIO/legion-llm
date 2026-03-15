# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Settings do
  subject(:defaults) { described_class.default }

  # ─── 1. Default settings include :routing key ─────────────────────────────────

  describe '.default' do
    it 'includes a :routing key' do
      expect(defaults).to have_key(:routing)
    end
  end

  # ─── 2. Routing defaults to disabled ─────────────────────────────────────────

  describe '.routing_defaults' do
    subject(:routing) { described_class.routing_defaults }

    it 'defaults routing to disabled' do
      expect(routing[:enabled]).to be false
    end

    # ─── 3. Includes default_intent with privacy/capability/cost ──────────────

    describe 'default_intent' do
      subject(:intent) { described_class.routing_defaults[:default_intent] }

      it 'includes a :default_intent key' do
        expect(described_class.routing_defaults).to have_key(:default_intent)
      end

      it 'has a privacy dimension' do
        expect(intent).to have_key(:privacy)
        expect(intent[:privacy]).to eq('normal')
      end

      it 'has a capability dimension' do
        expect(intent).to have_key(:capability)
        expect(intent[:capability]).to eq('moderate')
      end

      it 'has a cost dimension' do
        expect(intent).to have_key(:cost)
        expect(intent[:cost]).to eq('normal')
      end
    end

    # ─── 4. Includes tier definitions (local, fleet, cloud) ───────────────────

    describe 'tiers' do
      subject(:tiers) { described_class.routing_defaults[:tiers] }

      it 'includes a :tiers key' do
        expect(described_class.routing_defaults).to have_key(:tiers)
      end

      it 'defines a local tier with ollama provider' do
        expect(tiers).to have_key(:local)
        expect(tiers[:local][:provider]).to eq('ollama')
      end

      it 'defines a fleet tier with queue and timeout' do
        expect(tiers).to have_key(:fleet)
        expect(tiers[:fleet][:queue]).to eq('llm.inference')
        expect(tiers[:fleet][:timeout_seconds]).to eq(30)
      end

      it 'defines a cloud tier with providers list' do
        expect(tiers).to have_key(:cloud)
        expect(tiers[:cloud][:providers]).to eq(%w[bedrock anthropic])
      end
    end

    # ─── 5. Includes health config with circuit_breaker sub-hash ──────────────

    describe 'health' do
      subject(:health) { described_class.routing_defaults[:health] }

      it 'includes a :health key' do
        expect(described_class.routing_defaults).to have_key(:health)
      end

      it 'has a window_seconds setting' do
        expect(health[:window_seconds]).to eq(300)
      end

      it 'includes a circuit_breaker sub-hash' do
        expect(health).to have_key(:circuit_breaker)
        expect(health[:circuit_breaker]).to be_a(Hash)
      end

      it 'circuit_breaker has failure_threshold' do
        expect(health[:circuit_breaker][:failure_threshold]).to eq(3)
      end

      it 'circuit_breaker has cooldown_seconds' do
        expect(health[:circuit_breaker][:cooldown_seconds]).to eq(60)
      end

      it 'has latency_penalty_threshold_ms' do
        expect(health[:latency_penalty_threshold_ms]).to eq(5000)
      end

      it 'includes a budget sub-hash with nil limits' do
        expect(health).to have_key(:budget)
        expect(health[:budget][:daily_limit_usd]).to be_nil
        expect(health[:budget][:monthly_limit_usd]).to be_nil
      end
    end

    # ─── 6. Includes empty rules array ────────────────────────────────────────

    describe 'rules' do
      it 'includes a :rules key' do
        expect(described_class.routing_defaults).to have_key(:rules)
      end

      it 'defaults rules to an empty array' do
        expect(described_class.routing_defaults[:rules]).to eq([])
      end
    end
  end

  # ─── Integration: routing key wired into default ──────────────────────────────

  describe 'routing key in default hash' do
    it 'routing key in default equals routing_defaults' do
      expect(defaults[:routing]).to eq(described_class.routing_defaults)
    end
  end
end
