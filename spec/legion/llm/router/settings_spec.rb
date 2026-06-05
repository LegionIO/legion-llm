# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Settings do
  subject(:defaults) { described_class.default }

  describe '.default' do
    it 'includes a :routing key' do
      expect(defaults).to have_key(:routing)
    end

    it 'includes fleet dispatch defaults' do
      expect(defaults).to include(:fleet)
      expect(defaults.dig(:fleet, :dispatch, :enabled)).to be(false)
    end

    it 'does not include legacy gateway defaults' do
      expect(defaults).not_to have_key(:gateway)
    end
  end

  describe '.validate!' do
    it 'rejects legacy routing.use_fleet settings' do
      legacy = { routing: { use_fleet: false }, fleet: { dispatch: { enabled: true } } }

      expect do
        described_class.validate!(legacy)
      end.to raise_error(ArgumentError, /routing\.use_fleet/)
    end
  end

  describe 'Legion::Settings[:llm] access' do
    it 'reads nested symbol-keyed settings' do
      Legion::Settings[:llm][:routing] = { fleet: { timeout_seconds: 45 } }
      expect(Legion::Settings[:llm][:routing][:fleet][:timeout_seconds]).to eq(45)
    end

    it 'writes to the canonical LLM settings store' do
      Legion::Settings[:llm][:connected] = true
      expect(Legion::Settings[:llm][:connected]).to be true
    end
  end

  describe '.register_defaults!' do
    it 'registers LLM defaults via register_library' do
      allow(Legion::Settings).to receive(:register_library)

      described_class.register_defaults!

      expect(Legion::Settings).to have_received(:register_library).with(:llm, hash_including(enabled: true))
    end
  end

  describe '.routing_defaults' do
    subject(:routing) { described_class.routing_defaults }

    it 'defaults routing to enabled' do
      expect(routing[:enabled]).to be true
    end

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
        expect(tiers[:fleet][:queue]).to eq('llm.fleet')
        expect(tiers[:fleet][:routing_style]).to eq(:shared_lane)
        expect(tiers[:fleet][:timeout_seconds]).to eq(30)
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

    it 'defines tier_priority in correct order' do
      routing = described_class.routing_defaults
      expect(routing[:tier_priority]).to eq(%w[local direct fleet cloud frontier])
    end

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
      expect(routing[:escalation][:enabled]).to be false
      expect(routing[:escalation][:max_attempts]).to eq(3)
      expect(routing[:escalation][:quality_threshold]).to eq(0)
    end
  end

  describe 'routing key in default hash' do
    it 'routing key in default equals routing_defaults' do
      expect(defaults[:routing]).to eq(described_class.routing_defaults)
    end
  end
end
