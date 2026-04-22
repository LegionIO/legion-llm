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

    it 'defaults routing to enabled' do
      expect(routing[:enabled]).to be true
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

    # ─── 4. Includes tier definitions (local, fleet, openai_compat, cloud, frontier) ───

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
        expect(tiers[:fleet][:queue]).to eq('llm.request')
        expect(tiers[:fleet][:timeout_seconds]).to eq(30)
      end

      it 'includes openai_compat tier config' do
        expect(tiers).to have_key(:openai_compat)
      end

      it 'openai_compat tier has gateways list' do
        expect(tiers[:openai_compat][:gateways]).to eq([])
      end

      it 'cloud tier includes managed providers only' do
        expect(tiers).to have_key(:cloud)
        expect(tiers[:cloud][:providers]).to eq(%w[bedrock azure gemini])
      end

      it 'includes frontier tier config' do
        expect(tiers).to have_key(:frontier)
      end

      it 'frontier tier includes direct-API providers' do
        expect(tiers[:frontier][:providers]).to eq(%w[anthropic openai])
      end
    end

    # ─── 4b. tier_priority order ─────────────────────────────────────────────

    it 'defines tier_priority in correct order' do
      routing = described_class.routing_defaults
      expect(routing[:tier_priority]).to eq(%w[local fleet openai_compat cloud frontier])
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

  describe 'escalation defaults' do
    it 'includes escalation settings in routing defaults' do
      routing = Legion::LLM::Settings.routing_defaults
      expect(routing[:escalation]).to be_a(Hash)
      expect(routing[:escalation][:enabled]).to be true
      expect(routing[:escalation][:max_attempts]).to eq(3)
      expect(routing[:escalation][:quality_threshold]).to eq(0)
    end
  end

  # ─── Integration: routing key wired into default ──────────────────────────────

  describe 'routing key in default hash' do
    it 'routing key in default equals routing_defaults' do
      expect(defaults[:routing]).to eq(described_class.routing_defaults)
    end
  end
end
