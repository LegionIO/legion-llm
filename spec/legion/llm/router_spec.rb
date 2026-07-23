# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/health_tracker'
require 'legion/llm/router'

RSpec.describe Legion::LLM::Router do
  before do
    described_class.reset!
  end

  # ─── 9. health_tracker returns a HealthTracker instance ──────────────────────

  describe '.health_tracker' do
    it 'returns a HealthTracker instance' do
      expect(described_class.health_tracker).to be_a(Legion::LLM::Router::HealthTracker)
    end
  end

  # ─── 10. health_tracker is persistent across calls ────────────────────────────

  describe '.health_tracker persistence' do
    it 'returns the same object on repeated calls' do
      first  = described_class.health_tracker
      second = described_class.health_tracker
      expect(first).to be(second)
    end

    it 'returns a new object after reset!' do
      first = described_class.health_tracker
      described_class.reset!
      second = described_class.health_tracker
      expect(first).not_to be(second)
    end
  end

  describe '.health_tracker with custom health settings' do
    it 'honors routing.health settings when building the tracker' do
      Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                        routing: {
                                          enabled: true,
                                          health:  {
                                            window_seconds:  42,
                                            circuit_breaker: {
                                              failure_threshold: 2,
                                              cooldown_seconds:  15
                                            }
                                          }
                                        }
                                      ))
      described_class.reset!

      tracker = described_class.health_tracker

      expect(tracker.instance_variable_get(:@window_seconds)).to eq(42)
      expect(tracker.instance_variable_get(:@failure_threshold)).to eq(2)
      expect(tracker.instance_variable_get(:@cooldown_seconds)).to eq(15)
    end
  end

  # ─── 12. routing_enabled? false when disabled ─────────────────────────────────

  describe '.routing_enabled? when disabled' do
    it 'returns false when enabled is false' do
      Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(routing: { enabled: false }))
      expect(described_class.routing_enabled?).to be false
    end

    it 'returns false when routing settings are absent' do
      Legion::Settings.set_prop(:llm, {})
      expect(described_class.routing_enabled?).to be false
    end
  end

  # ─── 12a. auto_rules_populated? ─────────────────────────────────────────────

  describe '.auto_rules_populated?' do
    it 'returns false before populate_auto_rules is called' do
      expect(described_class.auto_rules_populated?).to be false
    end

    it 'stays false after populate_auto_rules (no-op in P4 — rule engine removed)' do
      described_class.populate_auto_rules({})
      expect(described_class.auto_rules_populated?).to be false
    end

    it 'returns false after reset!' do
      described_class.reset!
      expect(described_class.auto_rules_populated?).to be false
    end
  end

  describe '.infer_provider_for_model' do
    {
      'qwen3.5:latest'                    => :ollama,
      'qwen3:7b'                          => :ollama,
      'llama3:70b'                        => :ollama,
      'mistral:latest'                    => :ollama,
      'phi3:mini'                         => :ollama,
      'deepseek-coder:6.7b'               => :ollama,
      'nomic-embed-text:latest'           => :ollama,
      'us.anthropic.claude-sonnet-4-6-v1' => :bedrock,
      'us.meta.llama3-70b-instruct-v1:0'  => :bedrock,
      'gpt-4o'                            => :openai,
      'gpt-4o-mini'                       => :openai,
      'o1-preview'                        => :openai,
      'o3-mini'                           => :openai,
      'o4-mini'                           => :openai,
      'claude-sonnet-4-6'                 => :anthropic,
      'claude-3-5-haiku-20241022'         => :anthropic,
      'gemini-2.0-flash'                  => :gemini,
      'gemini-1.5-pro'                    => :gemini
    }.each do |model, expected_provider|
      it "infers #{expected_provider} for #{model}" do
        expect(described_class.infer_provider_for_model(model)).to eq(expected_provider)
      end
    end

    it 'returns nil for nil model' do
      expect(described_class.infer_provider_for_model(nil)).to be_nil
    end

    it 'returns nil for empty string' do
      expect(described_class.infer_provider_for_model('')).to be_nil
    end

    it 'returns nil for unrecognized model names' do
      expect(described_class.infer_provider_for_model('some-custom-model')).to be_nil
    end

    it 'infers ollama for colon-pattern model names (ollama tag format)' do
      # After P3, discover_provider_for_model is deleted. colon-separated names
      # (the Ollama "model:tag" format) are inferred as :ollama via OLLAMA_MODEL_PATTERN.
      expect(described_class.infer_provider_for_model('qwen3.6:27b')).to eq(:ollama)
    end

    it 'falls back to static inference when discovery cache is unavailable' do
      stub_const('Legion::LLM::Discovery', Module.new)

      expect(described_class.infer_provider_for_model('qwen3:7b')).to eq(:ollama)
    end
  end

  # ─── tier_available? for :direct tier ────────────────────────────────────────

  describe '.tier_available?' do
    before do
      # Remove the blanket stub so we test the real method
      allow(described_class).to receive(:tier_available?).and_call_original
      allow(described_class).to receive(:privacy_mode?).and_return(false)
    end

    it 'returns true for :direct tier' do
      expect(described_class.tier_available?(:direct)).to be true
    end

    it 'returns true for :local tier' do
      expect(described_class.tier_available?(:local)).to be true
    end
  end

  # ─── external_tier? via TIER_EXTERNAL constant ───────────────────────────────

  describe '.external_tier? (via TIER_EXTERNAL)' do
    it 'returns false for :direct' do
      expect(described_class.send(:external_tier?, :direct)).to be false
    end

    it 'returns false for :local' do
      expect(described_class.send(:external_tier?, :local)).to be false
    end

    it 'returns true for :cloud' do
      expect(described_class.send(:external_tier?, :cloud)).to be true
    end

    it 'returns true for :frontier' do
      expect(described_class.send(:external_tier?, :frontier)).to be true
    end

    it 'returns false for :local' do
      expect(described_class.send(:external_tier?, :local)).to be false
    end
  end

  # ─── TIER_EXTERNAL constant ─────────────────────────────────────────────────

  describe 'TIER_EXTERNAL' do
    it 'is a frozen Set of external tiers' do
      expect(described_class::TIER_EXTERNAL).to be_a(Set)
      expect(described_class::TIER_EXTERNAL).to be_frozen
      expect(described_class::TIER_EXTERNAL).to eq(Set[:cloud, :frontier])
    end
  end

  describe '.request_lane range sieve' do
    let(:rng) { Random.new(42) }

    let(:v100_lane) do
      { id: 'direct:vllm:v100:inference:qwen', tier: :direct, provider_family: :vllm,
        instance_id: :v100, model: 'qwen', type: :inference, lane_weight: 100,
        capabilities: [:completion], limits: { context_window: 16_000 },
        preferred_min_context_tokens: 0, preferred_max_context_tokens: 250 }
    end

    let(:h200_lane) do
      { id: 'direct:vllm:h200:inference:qwen', tier: :direct, provider_family: :vllm,
        instance_id: :h200, model: 'qwen', type: :inference, lane_weight: 100,
        capabilities: [:completion], limits: { context_window: 262_000 },
        preferred_min_context_tokens: 250, preferred_max_context_tokens: 32_000 }
    end

    let(:mi355x_lane) do
      { id: 'direct:vllm:mi355x:inference:qwen', tier: :direct, provider_family: :vllm,
        instance_id: :mi355x, model: 'qwen', type: :inference, lane_weight: 100,
        capabilities: [:completion], limits: { context_window: 262_000 },
        preferred_min_context_tokens: 32_000, preferred_max_context_tokens: 262_000 }
    end

    let(:generalist_lane) do
      { id: 'direct:vllm:generalist:inference:qwen', tier: :direct, provider_family: :vllm,
        instance_id: :generalist, model: 'qwen', type: :inference, lane_weight: 100,
        capabilities: [:completion], limits: { context_window: 262_000 } }
    end

    before do
      allow(Legion::LLM::Inventory).to receive(:lanes).and_return(
        [v100_lane, h200_lane, mi355x_lane, generalist_lane]
      )
    end

    context 'specific range matching' do
      it 'routes small context to V100 sweet spot' do
        result = described_class.request_lane(type: :inference, estimated_context: 200, rng: rng)
        expect(result[:instance_id]).to eq(:v100)
      end

      it 'routes medium context to H200 sweet spot' do
        result = described_class.request_lane(type: :inference, estimated_context: 10_000, rng: rng)
        expect(result[:instance_id]).to eq(:h200)
      end

      it 'routes large context to MI355X sweet spot' do
        result = described_class.request_lane(type: :inference, estimated_context: 100_000, rng: rng)
        expect(result[:instance_id]).to eq(:mi355x)
      end

      it 'uses lower-inclusive upper-exclusive boundaries' do
        result = described_class.request_lane(type: :inference, estimated_context: 250, rng: rng)
        expect(result[:instance_id]).to eq(:h200)
      end

      it 'prefers higher-weight lane within the specific match pool' do
        heavy_h200 = h200_lane.merge(lane_weight: 200)
        allow(Legion::LLM::Inventory).to receive(:lanes).and_return([v100_lane, heavy_h200, mi355x_lane])
        result = described_class.request_lane(type: :inference, estimated_context: 10_000, rng: rng)
        expect(result[:instance_id]).to eq(:h200)
      end
    end

    context 'generalist fallback' do
      it 'uses generalist when no specific range matches' do
        lanes_with_gap = [
          v100_lane.merge(preferred_min_context_tokens: 0, preferred_max_context_tokens: 100),
          h200_lane.merge(preferred_min_context_tokens: 500, preferred_max_context_tokens: 1000),
          generalist_lane
        ]
        allow(Legion::LLM::Inventory).to receive(:lanes).and_return(lanes_with_gap)
        result = described_class.request_lane(type: :inference, estimated_context: 200, rng: rng)
        expect(result[:instance_id]).to eq(:generalist)
      end

      it 'does NOT include generalist in specific pool when specific matches exist' do
        allow(Legion::LLM::Inventory).to receive(:lanes).and_return(
          [v100_lane, generalist_lane.merge(lane_weight: 999)]
        )
        result = described_class.request_lane(type: :inference, estimated_context: 100, rng: rng)
        expect(result[:instance_id]).to eq(:v100)
      end
    end

    context 'full eligible fallback' do
      it 'falls back to full eligible set when no specific match and no generalists' do
        lanes_all_specific = [
          v100_lane.merge(preferred_min_context_tokens: 0, preferred_max_context_tokens: 50),
          h200_lane.merge(preferred_min_context_tokens: 500, preferred_max_context_tokens: 1000)
        ]
        allow(Legion::LLM::Inventory).to receive(:lanes).and_return(lanes_all_specific)
        result = described_class.request_lane(type: :inference, estimated_context: 200, rng: rng)
        expect(result).not_to be_nil
      end
    end

    context 'escalation via tried_lanes' do
      it 'drains specific pool then spills to generalist' do
        allow(Legion::LLM::Inventory).to receive(:lanes).and_return([v100_lane, generalist_lane])
        first = described_class.request_lane(type: :inference, estimated_context: 100, rng: rng)
        expect(first[:instance_id]).to eq(:v100)

        second = described_class.request_lane(
          type: :inference, estimated_context: 100, tried_lanes: [v100_lane[:id]], rng: rng
        )
        expect(second[:instance_id]).to eq(:generalist)
      end

      it 'drains generalist then spills to full eligible' do
        specific_only = v100_lane.merge(
          id: 'direct:vllm:other:inference:qwen', instance_id: :other,
          preferred_min_context_tokens: 500, preferred_max_context_tokens: 1000
        )
        allow(Legion::LLM::Inventory).to receive(:lanes).and_return([specific_only, generalist_lane])
        first = described_class.request_lane(type: :inference, estimated_context: 200, rng: rng)
        expect(first[:instance_id]).to eq(:generalist)

        second = described_class.request_lane(
          type: :inference, estimated_context: 200, tried_lanes: [generalist_lane[:id]], rng: rng
        )
        expect(second[:instance_id]).to eq(:other)
      end
    end

    context 'nil estimated_context' do
      it 'skips range sieve entirely' do
        result = described_class.request_lane(type: :inference, estimated_context: nil, rng: rng)
        expect(result).not_to be_nil
      end
    end

    context 'integration with full fleet' do
      let(:fleet_lanes) do
        [
          { id: 'direct:vllm:apollo:inference:qwen', tier: :direct, provider_family: :vllm,
            instance_id: :apollo, model: 'qwen', type: :inference, lane_weight: 100,
            capabilities: [:completion], limits: { context_window: 16_000 },
            preferred_min_context_tokens: 0, preferred_max_context_tokens: 250 },
          { id: 'direct:vllm:h200:inference:qwen', tier: :direct, provider_family: :vllm,
            instance_id: :h200, model: 'qwen', type: :inference, lane_weight: 100,
            capabilities: [:completion], limits: { context_window: 262_000 },
            preferred_min_context_tokens: 250, preferred_max_context_tokens: 32_000 },
          { id: 'direct:vllm:helios_a:inference:qwen', tier: :direct, provider_family: :vllm,
            instance_id: :helios_a, model: 'qwen', type: :inference, lane_weight: 100,
            capabilities: [:completion], limits: { context_window: 262_000 },
            preferred_min_context_tokens: 32_000, preferred_max_context_tokens: 262_000 },
          { id: 'cloud:anthropic:default:inference:claude', tier: :cloud, provider_family: :anthropic,
            instance_id: :default, model: 'claude', type: :inference, lane_weight: 80,
            capabilities: %i[completion thinking], limits: { context_window: 200_000 } }
        ]
      end

      before do
        allow(Legion::LLM::Inventory).to receive(:lanes).and_return(fleet_lanes)
      end

      it 'routes GAIA tick to apollo' do
        result = described_class.request_lane(type: :inference, estimated_context: 100, rng: rng)
        expect(result[:instance_id]).to eq(:apollo)
      end

      it 'routes standard user prompt to H200' do
        result = described_class.request_lane(type: :inference, estimated_context: 5_000, rng: rng)
        expect(result[:instance_id]).to eq(:h200)
      end

      it 'routes heavy context to helios MI355X' do
        result = described_class.request_lane(type: :inference, estimated_context: 80_000, rng: rng)
        expect(result[:instance_id]).to eq(:helios_a)
      end

      it 'anthropic generalist used when all vllm lanes tried' do
        tried = fleet_lanes.select { |l| l[:provider_family] == :vllm }.map { |l| l[:id] }
        result = described_class.request_lane(
          type: :inference, estimated_context: 5_000, tried_lanes: tried, rng: rng
        )
        expect(result[:instance_id]).to eq(:default)
        expect(result[:provider_family]).to eq(:anthropic)
      end

      it 'returns nil when all lanes exhausted' do
        tried = fleet_lanes.map { |l| l[:id] }
        result = described_class.request_lane(
          type: :inference, estimated_context: 5_000, tried_lanes: tried, rng: rng
        )
        expect(result).to be_nil
      end
    end
  end
end
