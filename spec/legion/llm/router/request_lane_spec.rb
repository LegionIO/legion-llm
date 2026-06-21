# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Router, '#request_lane' do
  let(:rng) { Random.new(42) }

  def write_lane(provider:, model:, instance: :default, tier: :direct, type: :inference,
                 capabilities: [], limits: {}, lane_weight: nil, health: nil)
    lane = {
      id:              "#{tier}:#{provider}:#{instance}:#{type}:#{model}",
      tier:            tier,
      provider_family: provider,
      instance_id:     instance,
      model:           model,
      type:            type,
      capabilities:    capabilities,
      limits:          limits
    }
    opts = { lane: lane }
    opts[:health] = health if health
    if lane_weight
      # Write without lane_weight first, then re-write with explicit weight to bypass compute
      written = Legion::LLM::Inventory.write_lane(**opts)
      # Patch the lane_weight directly for testing purposes
      Legion::LLM::Inventory.send(:live_map).put(lane[:id], written.merge(lane_weight: lane_weight))
    else
      Legion::LLM::Inventory.write_lane(**opts)
    end
  end

  after { Legion::LLM::Inventory.reset_live_store! }

  # ─── Hard filters ──────────────────────────────────────────────────────────

  describe 'hard filters' do
    it 'filters by type — returns nil when no lane matches the type' do
      write_lane(provider: :vllm, model: 'gemma-12b', type: :inference)
      expect(Legion::LLM::Router.request_lane(type: :embedding, rng: rng)).to be_nil
    end

    it 'filters by type — returns lane when type matches' do
      write_lane(provider: :vllm, model: 'gemma-12b', type: :inference)
      lane = Legion::LLM::Router.request_lane(type: :inference, rng: rng)
      expect(lane).not_to be_nil
      expect(lane[:type]).to eq(:inference)
    end

    it 'filters by tiers (hard allow-set) — excludes non-matching tier' do
      write_lane(provider: :vllm, model: 'gemma-12b', tier: :direct)
      write_lane(provider: :bedrock, model: 'claude-sonnet-4-6', tier: :cloud)
      lane = Legion::LLM::Router.request_lane(type: :inference, tiers: [:direct], rng: rng)
      expect(lane[:tier]).to eq(:direct)
      expect(lane[:provider_family]).to eq(:vllm)
    end

    it 'filters by tiers — cloud filter excludes local lane' do
      write_lane(provider: :vllm, model: 'gemma-12b', tier: :direct)
      expect(Legion::LLM::Router.request_lane(type: :inference, tiers: [:cloud], rng: rng)).to be_nil
    end

    it 'filters by providers (hard allow-set)' do
      write_lane(provider: :vllm, model: 'gemma-12b', tier: :direct)
      write_lane(provider: :bedrock, model: 'claude-sonnet-4-6', tier: :cloud)
      lane = Legion::LLM::Router.request_lane(type: :inference, providers: [:bedrock], rng: rng)
      expect(lane[:provider_family]).to eq(:bedrock)
    end

    it 'filters by instances (hard allow-set)' do
      write_lane(provider: :vllm, instance: :apollo, model: 'gemma-12b')
      write_lane(provider: :vllm, instance: :hermes, model: 'gemma-12b')
      lane = Legion::LLM::Router.request_lane(type: :inference, instances: [:apollo], rng: rng)
      expect(lane[:instance_id]).to eq(:apollo)
    end

    it 'filters by models (hard allow-set)' do
      write_lane(provider: :vllm, model: 'gemma-12b')
      write_lane(provider: :vllm, model: 'llama3-8b')
      lane = Legion::LLM::Router.request_lane(type: :inference, models: ['llama3-8b'], rng: rng)
      expect(lane[:model]).to eq('llama3-8b')
    end

    it 'filters Bedrock region-prefixed model ids against unprefixed inventory lanes' do
      write_lane(provider: :bedrock, model: 'anthropic.claude-sonnet-4-6',
                 tier: :cloud, capabilities: %i[tools streaming])

      lane = Legion::LLM::Router.request_lane(
        type:         :inference,
        models:       ['us.anthropic.claude-sonnet-4-6'],
        capabilities: [:tools],
        rng:          rng
      )

      expect(lane).not_to be_nil
      expect(lane[:provider_family]).to eq(:bedrock)
      expect(lane[:model]).to eq('anthropic.claude-sonnet-4-6')
    end

    it 'empty filter lists are permissive (all-pass)' do
      write_lane(provider: :vllm, model: 'gemma-12b')
      lane = Legion::LLM::Router.request_lane(type: :inference, tiers: [], providers: [], instances: [], models: [], rng: rng)
      expect(lane).not_to be_nil
    end

    it 'filters by capabilities — lane must be a superset of requested capabilities' do
      write_lane(provider: :vllm, model: 'gemma-12b', capabilities: [:streaming])
      write_lane(provider: :anthropic, model: 'claude-sonnet-4-6', capabilities: %i[tools streaming])
      lane = Legion::LLM::Router.request_lane(type: :inference, capabilities: [:tools], rng: rng)
      expect(lane[:provider_family]).to eq(:anthropic)
    end

    it 'capability normalization — request :tools matches lane :function_calling (PR #152 I1)' do
      write_lane(provider: :openai, model: 'gpt-5.4', capabilities: [:function_calling])
      lane = Legion::LLM::Router.request_lane(type: :inference, capabilities: [:tools], rng: rng)
      expect(lane).not_to be_nil
      expect(lane[:provider_family]).to eq(:openai)
    end

    it 'capability normalization — request :tools matches lane :function_calling (aliases collapse to canonical)' do
      write_lane(provider: :vllm, model: 'gemma-12b', capabilities: [:function_calling])
      lane = Legion::LLM::Router.request_lane(type: :inference, capabilities: [:tools], rng: rng)
      expect(lane).not_to be_nil
    end

    it 'capability normalization — request :tools matches lane declaring both :function_calling and :tools' do
      write_lane(provider: :anthropic, model: 'claude-sonnet-4-6',
                 tier: :frontier, capabilities: %i[function_calling tools])
      lane = Legion::LLM::Router.request_lane(type: :inference, capabilities: [:tool_use], rng: rng)
      expect(lane).not_to be_nil
    end

    it 'filters by thinking: :require — requires :thinking capability' do
      write_lane(provider: :vllm, model: 'gemma-12b', capabilities: [:streaming])
      write_lane(provider: :anthropic, model: 'claude-sonnet-4-6', capabilities: %i[streaming thinking])
      lane = Legion::LLM::Router.request_lane(type: :inference, thinking: :require, rng: rng)
      expect(lane[:provider_family]).to eq(:anthropic)
    end

    it 'thinking: :forbid is NOT a filter — returns any lane including thinking-capable ones' do
      write_lane(provider: :anthropic, model: 'claude-sonnet-4-6', capabilities: [:thinking])
      lane = Legion::LLM::Router.request_lane(type: :inference, thinking: :forbid, rng: rng)
      expect(lane).not_to be_nil
    end

    it 'thinking: :any is a no-op filter' do
      write_lane(provider: :vllm, model: 'gemma-12b')
      lane = Legion::LLM::Router.request_lane(type: :inference, thinking: :any, rng: rng)
      expect(lane).not_to be_nil
    end

    it 'filters by privacy: :strict — strips cloud and frontier tiers' do
      write_lane(provider: :vllm, model: 'gemma-12b', tier: :direct)
      write_lane(provider: :bedrock, model: 'claude-sonnet-4-6', tier: :cloud)
      write_lane(provider: :anthropic, model: 'claude-sonnet-4-6', tier: :frontier)
      lane = Legion::LLM::Router.request_lane(type: :inference, privacy: :strict, rng: rng)
      expect(lane[:tier]).to eq(:direct)
    end

    it 'privacy: :strict returns nil when only external tiers exist' do
      write_lane(provider: :bedrock, model: 'claude-sonnet-4-6', tier: :cloud)
      expect(Legion::LLM::Router.request_lane(type: :inference, privacy: :strict, rng: rng)).to be_nil
    end

    it 'filters by estimated_context — lane context_window must be >= request' do
      write_lane(provider: :vllm, model: 'small-model', limits: { context_window: 8_000 })
      write_lane(provider: :anthropic, model: 'claude-sonnet-4-6', tier: :frontier,
                 limits: { context_window: 200_000 })
      lane = Legion::LLM::Router.request_lane(type: :inference, estimated_context: 50_000, rng: rng)
      expect(lane[:provider_family]).to eq(:anthropic)
    end

    it 'treats missing context_window as unlimited (nil = pass)' do
      write_lane(provider: :vllm, model: 'gemma-12b')
      lane = Legion::LLM::Router.request_lane(type: :inference, estimated_context: 50_000, rng: rng)
      expect(lane).not_to be_nil
    end
  end

  # ─── tried_lanes exclusion ─────────────────────────────────────────────────

  describe 'tried_lanes exclusion' do
    it 'excludes lanes by id' do
      write_lane(provider: :vllm, instance: :a, model: 'gemma-12b')
      write_lane(provider: :vllm, instance: :b, model: 'gemma-12b')
      lane = Legion::LLM::Router.request_lane(
        type: :inference, rng: rng,
        tried_lanes: ['direct:vllm:a:inference:gemma-12b']
      )
      expect(lane[:instance_id]).to eq(:b)
    end

    it 'falls back to lower-weight bucket when top bucket is fully excluded' do
      # Two tiers — direct (higher default weight) and cloud (lower)
      write_lane(provider: :vllm, model: 'gemma-12b', tier: :direct)
      write_lane(provider: :bedrock, model: 'claude-sonnet-4-6', tier: :cloud)
      # Exclude the direct lane
      direct_id = 'direct:vllm:default:inference:gemma-12b'
      lane = Legion::LLM::Router.request_lane(type: :inference, tried_lanes: [direct_id], rng: rng)
      expect(lane[:tier]).to eq(:cloud)
    end

    it 'returns nil when all eligible lanes are in tried_lanes' do
      write_lane(provider: :vllm, model: 'gemma-12b')
      id = 'direct:vllm:default:inference:gemma-12b'
      expect(Legion::LLM::Router.request_lane(type: :inference, tried_lanes: [id], rng: rng)).to be_nil
    end
  end

  # ─── lane_weight ≤ 0 filtering ─────────────────────────────────────────────

  describe 'lane_weight ≤ 0 filtering' do
    it 'rejects open-circuit lanes (lane_weight negative)' do
      write_lane(provider: :vllm, model: 'gemma-12b',
                 health: { circuit_state: :open, denied: false, available: false, adjustment: 0 })
      expect(Legion::LLM::Router.request_lane(type: :inference, rng: rng)).to be_nil
    end

    it 'rejects denied lanes (lane_weight negative via denied bit)' do
      write_lane(provider: :vllm, model: 'gemma-12b',
                 health: { circuit_state: :closed, denied: true, available: false, adjustment: 0 })
      expect(Legion::LLM::Router.request_lane(type: :inference, rng: rng)).to be_nil
    end

    it 'keeps half_open lanes (lane_weight positive but reduced — still eligible)' do
      write_lane(provider: :vllm, model: 'gemma-12b',
                 health: { circuit_state: :half_open, denied: false, available: true, adjustment: 0 })
      lane = Legion::LLM::Router.request_lane(type: :inference, rng: rng)
      expect(lane).not_to be_nil
      expect(lane[:health][:circuit_state]).to eq(:half_open)
    end
  end

  # ─── Bucket selection ──────────────────────────────────────────────────────

  describe 'bucket selection' do
    it 'always picks from the max-lane_weight bucket' do
      # Write two lanes with different weights; higher-weight should always win
      write_lane(provider: :vllm, instance: :low, model: 'small-model')
      write_lane(provider: :anthropic, instance: :default, model: 'claude-sonnet-4-6',
                 tier: :frontier)
      # Patch low weight to ensure vllm has lower weight
      low_id = 'direct:vllm:low:inference:small-model'
      low_lane = Legion::LLM::Inventory.lane(id: low_id)
      Legion::LLM::Inventory.send(:live_map).put(low_id, low_lane.merge(lane_weight: 1)) if low_lane

      # Should always pick the anthropic lane (highest weight)
      100.times do
        lane = Legion::LLM::Router.request_lane(type: :inference, rng: Random.new(rand(1000)))
        expect(lane[:provider_family]).to eq(:anthropic)
      end
    end

    it 'samples within bucket with seeded RNG (deterministic within bucket)' do
      # Same seed → same result; 3 equal-weight lanes in one bucket
      3.times do |i|
        write_lane(provider: :vllm, instance: :"i#{i}", model: 'gemma-12b')
      end
      first  = Legion::LLM::Router.request_lane(type: :inference, rng: Random.new(42))
      second = Legion::LLM::Router.request_lane(type: :inference, rng: Random.new(42))
      expect(first[:instance_id]).to eq(second[:instance_id])
    end

    it 'spreads across the bucket with different seeds' do
      3.times do |i|
        write_lane(provider: :vllm, instance: :"i#{i}", model: 'gemma-12b')
      end
      results = 30.times.map { |i| Legion::LLM::Router.request_lane(type: :inference, rng: Random.new(i))[:instance_id] }
      expect(results.uniq.size).to be > 1
    end
  end

  # ─── Exhaustion ────────────────────────────────────────────────────────────

  describe 'exhaustion' do
    it 'returns nil when all lanes are filtered out by hard filters' do
      write_lane(provider: :vllm, model: 'gemma-12b', tier: :direct)
      expect(Legion::LLM::Router.request_lane(type: :inference, tiers: [:cloud], rng: rng)).to be_nil
    end

    it 'returns nil when all eligible lanes are in tried_lanes' do
      write_lane(provider: :vllm, model: 'gemma-12b')
      write_lane(provider: :vllm, instance: :b, model: 'gemma-12b')
      tried = %w[direct:vllm:default:inference:gemma-12b direct:vllm:b:inference:gemma-12b]
      expect(Legion::LLM::Router.request_lane(type: :inference, tried_lanes: tried, rng: rng)).to be_nil
    end

    it 'returns nil when inventory is empty' do
      expect(Legion::LLM::Router.request_lane(type: :inference, rng: rng)).to be_nil
    end
  end

  # ─── No hail-mary (G24) ────────────────────────────────────────────────────

  describe 'no hail-mary (G24)' do
    it 'returns nil when providers filter excludes all lanes — even if default lane exists' do
      Legion::Settings.loader.settings[:llm][:default_provider] = :openai
      Legion::Settings.loader.settings[:llm][:default_model]    = 'gpt-5.5'
      write_lane(provider: :openai, model: 'gpt-5.5', tier: :frontier)

      expect(Legion::LLM::Router.request_lane(type: :inference, providers: [:bedrock], rng: rng)).to be_nil
    end

    it 'never bypasses lane_weight ≤ 0 — operator-disabled lane stays disabled' do
      write_lane(provider: :openai, model: 'gpt-5.5', tier: :frontier,
                 health: { circuit_state: :open, denied: false, available: false, adjustment: 0 })
      expect(Legion::LLM::Router.request_lane(type: :inference, rng: rng)).to be_nil
    end

    it 'configured default lane is not a hail-mary bypass — it must pass normal filters' do
      # Even with a configured default provider/model, filters must be respected
      Legion::Settings.loader.settings[:llm][:default_provider] = :anthropic
      Legion::Settings.loader.settings[:llm][:default_model]    = 'claude-sonnet-4-6'
      write_lane(provider: :anthropic, model: 'claude-sonnet-4-6', tier: :frontier)

      # Request with a bedrock-only filter → anthropic default not injected
      expect(Legion::LLM::Router.request_lane(type: :inference, providers: [:bedrock], rng: rng)).to be_nil
    end

    it 'settings key llm.routing.last_resort_default has no effect (G24)' do
      Legion::Settings.loader.settings[:llm][:routing] ||= {}
      Legion::Settings.loader.settings[:llm][:routing][:last_resort_default] = 'gpt-5.5'
      write_lane(provider: :openai, model: 'gpt-5.5', tier: :frontier)

      # Requesting with a filter that excludes openai → nil even with last_resort_default set
      expect(Legion::LLM::Router.request_lane(type: :inference, providers: [:bedrock], rng: rng)).to be_nil
    end
  end

  # ─── Bucket-G25 determinism ────────────────────────────────────────────────

  describe 'bucket-G25 determinism' do
    it 'same payload + same catalog + same seed = same lane (deterministic to bucket)' do
      3.times do |i|
        write_lane(provider: :vllm, instance: :"i#{i}", model: 'gemma-12b')
      end

      seed = 42
      result_a = Legion::LLM::Router.request_lane(type: :inference, rng: Random.new(seed))
      result_b = Legion::LLM::Router.request_lane(type: :inference, rng: Random.new(seed))
      expect(result_a[:id]).to eq(result_b[:id])
    end

    it 'same payload + same catalog + different seed = potentially different lane within bucket' do
      3.times do |i|
        write_lane(provider: :vllm, instance: :"i#{i}", model: 'gemma-12b')
      end

      results = 30.times.map { |i| Legion::LLM::Router.request_lane(type: :inference, rng: Random.new(i))[:id] }
      expect(results.uniq.size).to be > 1
    end

    it 'deterministic to weight-bucket: same weight bucket always wins across seeds' do
      write_lane(provider: :vllm, model: 'gemma-12b', tier: :direct)
      write_lane(provider: :bedrock, model: 'claude-sonnet-4-6', tier: :cloud)

      # Ensure direct > cloud by patching weights
      direct_id = 'direct:vllm:default:inference:gemma-12b'
      cloud_id  = 'cloud:bedrock:default:inference:claude-sonnet-4-6'
      direct_lane = Legion::LLM::Inventory.lane(id: direct_id)
      cloud_lane  = Legion::LLM::Inventory.lane(id: cloud_id)
      Legion::LLM::Inventory.send(:live_map).put(direct_id, direct_lane.merge(lane_weight: 200_000_000)) if direct_lane
      Legion::LLM::Inventory.send(:live_map).put(cloud_id, cloud_lane.merge(lane_weight: 100_000_000)) if cloud_lane

      100.times do |i|
        lane = Legion::LLM::Router.request_lane(type: :inference, rng: Random.new(i))
        expect(lane[:tier]).to eq(:direct)
      end
    end
  end

  # ─── M1 fast path ──────────────────────────────────────────────────────────

  describe 'M1 indexed read optimization' do
    it 'uses lanes_for when providers.size == 1 && instances.size <= 1' do
      write_lane(provider: :vllm, model: 'gemma-12b')
      expect(Legion::LLM::Inventory).to receive(:lanes_for).and_call_original
      Legion::LLM::Router.request_lane(type: :inference, providers: [:vllm], rng: rng)
    end

    it 'uses lanes directly when multiple providers are specified' do
      write_lane(provider: :vllm, model: 'gemma-12b')
      # With multiple providers, request_lane calls Inventory.lanes (not lanes_for)
      expect(Legion::LLM::Inventory).to receive(:lanes).and_call_original
      Legion::LLM::Router.request_lane(type: :inference, providers: %i[vllm bedrock], rng: rng)
    end
  end
end
