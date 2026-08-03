# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/health_tracker'
require 'legion/llm/router'

RSpec.describe 'Circuit-breaker half-open probe starvation fix' do
  let(:rng) { Random.new(42) }

  def build_lane(provider: :vllm, tier: :fleet, instance: :h200, model: 'gemma-4-31b-it', type: :inference)
    id = "#{tier}:#{provider}:#{instance}:#{type}:#{model}"
    {
      id:              id,
      tier:            tier,
      provider_family: provider,
      instance_id:     instance,
      model:           model.to_s,
      type:            type,
      capabilities:    %i[completion tools streaming],
      limits:          { context_window: 262_000 }
    }
  end

  before do
    Legion::Settings[:extensions][:llm][:vllm] ||= {}
    Legion::Settings[:extensions][:llm][:vllm][:weight]    ||= 100
    Legion::Settings[:extensions][:llm][:vllm][:instances] ||= {}
    Legion::Settings[:extensions][:llm][:vllm][:models]    ||= {}
    Legion::LLM::Router.reset!
  end

  describe 'sweep_circuits! advances open circuits past cooldown to half_open' do
    let(:tracker) { Legion::LLM::Router::HealthTracker.new(failure_threshold: 3, cooldown_seconds: 60, sweep_interval_seconds: 0) }

    it 'transitions an open circuit to half_open after cooldown expires' do
      Legion::LLM::Inventory.write_lane(lane: build_lane, ttl: 3600)

      3.times { tracker.report(provider: :vllm, instance: :h200, signal: :error, value: 1) }

      lane = Legion::LLM::Inventory.lane(id: 'fleet:vllm:h200:inference:gemma-4-31b-it')
      expect(lane[:health][:circuit_state]).to eq(:open)
      expect(lane[:lane_weight]).to be < 0

      circuit = tracker.instance_variable_get(:@circuits)['vllm/h200']
      circuit[:opened_at] = Time.now - 61

      tracker.sweep_circuits!

      lane = Legion::LLM::Inventory.lane(id: 'fleet:vllm:h200:inference:gemma-4-31b-it')
      expect(lane[:health][:circuit_state]).to eq(:half_open)
      expect(lane[:health][:available]).to eq(true)
      expect(lane[:lane_weight]).to be > 0
    end

    it 'does NOT transition circuits still within cooldown' do
      Legion::LLM::Inventory.write_lane(lane: build_lane, ttl: 3600)

      3.times { tracker.report(provider: :vllm, instance: :h200, signal: :error, value: 1) }

      circuit = tracker.instance_variable_get(:@circuits)['vllm/h200']
      circuit[:opened_at] = Time.now - 30

      tracker.sweep_circuits!

      lane = Legion::LLM::Inventory.lane(id: 'fleet:vllm:h200:inference:gemma-4-31b-it')
      expect(lane[:health][:circuit_state]).to eq(:open)
      expect(lane[:lane_weight]).to be < 0
    end

    it 'is throttled by sweep_interval_seconds' do
      throttled_tracker = Legion::LLM::Router::HealthTracker.new(
        failure_threshold: 3, cooldown_seconds: 60, sweep_interval_seconds: 10
      )
      Legion::LLM::Inventory.write_lane(lane: build_lane, ttl: 3600)

      3.times { throttled_tracker.report(provider: :vllm, instance: :h200, signal: :error, value: 1) }

      circuit = throttled_tracker.instance_variable_get(:@circuits)['vllm/h200']
      circuit[:opened_at] = Time.now - 61

      throttled_tracker.instance_variable_set(:@last_sweep_at, Time.now)
      throttled_tracker.sweep_circuits!

      lane = Legion::LLM::Inventory.lane(id: 'fleet:vllm:h200:inference:gemma-4-31b-it')
      expect(lane[:health][:circuit_state]).to eq(:open)
    end
  end

  describe 'Router.request_lane admits half_open lanes as probe candidates' do
    before do
      Legion::LLM::Inventory.write_lane(lane: build_lane, ttl: 3600)
    end

    it 'returns a half_open lane when it is the only one matching filters' do
      tracker = Legion::LLM::Router.health_tracker

      3.times { tracker.report(provider: :vllm, instance: :h200, signal: :error, value: 1) }

      circuit = tracker.instance_variable_get(:@circuits)['vllm/h200']
      circuit[:opened_at] = Time.now - 61
      tracker.instance_variable_set(:@last_sweep_at, Time.now - 10)

      result = Legion::LLM::Router.request_lane(
        type: :inference, models: ['gemma-4-31b-it'], capabilities: [:tools], rng: rng
      )
      expect(result).not_to be_nil
      expect(result[:id]).to eq('fleet:vllm:h200:inference:gemma-4-31b-it')
      expect(result[:health][:circuit_state]).to eq(:half_open)
    end

    it 'prefers a healthy lane over a half_open lane' do
      healthy_lane = build_lane(instance: :helios, model: 'gemma-4-31b-it')
      Legion::LLM::Inventory.write_lane(lane: healthy_lane, ttl: 3600)

      tracker = Legion::LLM::Router.health_tracker
      3.times { tracker.report(provider: :vllm, instance: :h200, signal: :error, value: 1) }

      circuit = tracker.instance_variable_get(:@circuits)['vllm/h200']
      circuit[:opened_at] = Time.now - 61
      tracker.instance_variable_set(:@last_sweep_at, Time.now - 10)

      result = Legion::LLM::Router.request_lane(
        type: :inference, models: ['gemma-4-31b-it'], capabilities: [:tools], rng: rng
      )
      expect(result[:instance_id]).to eq(:helios)
    end

    it 'closes the circuit after a successful probe request' do
      tracker = Legion::LLM::Router.health_tracker

      3.times { tracker.report(provider: :vllm, instance: :h200, signal: :error, value: 1) }
      circuit = tracker.instance_variable_get(:@circuits)['vllm/h200']
      circuit[:opened_at] = Time.now - 61
      tracker.instance_variable_set(:@last_sweep_at, Time.now - 10)

      result = Legion::LLM::Router.request_lane(
        type: :inference, models: ['gemma-4-31b-it'], rng: rng
      )
      expect(result).not_to be_nil

      tracker.report(provider: :vllm, instance: :h200, signal: :success, value: nil)

      lane = Legion::LLM::Inventory.lane(id: 'fleet:vllm:h200:inference:gemma-4-31b-it')
      expect(lane[:health][:circuit_state]).to eq(:closed)
      expect(lane[:lane_weight]).to be > 0
    end
  end

  describe 'fully-open and denied lanes remain excluded' do
    before do
      Legion::LLM::Inventory.write_lane(lane: build_lane, ttl: 3600)
    end

    it 'does NOT route to a lane still in cooldown (fully open)' do
      tracker = Legion::LLM::Router.health_tracker

      3.times { tracker.report(provider: :vllm, instance: :h200, signal: :error, value: 1) }

      circuit = tracker.instance_variable_get(:@circuits)['vllm/h200']
      circuit[:opened_at] = Time.now - 30
      tracker.instance_variable_set(:@last_sweep_at, Time.now - 10)

      result = Legion::LLM::Router.request_lane(
        type: :inference, models: ['gemma-4-31b-it'], rng: rng
      )
      expect(result).to be_nil
    end

    it 'does NOT route to a denied lane even after cooldown' do
      tracker = Legion::LLM::Router.health_tracker

      tracker.deny_model(provider: :vllm, instance: :h200, model: 'gemma-4-31b-it', reason: :access_denied)
      tracker.instance_variable_set(:@last_sweep_at, Time.now - 10)

      result = Legion::LLM::Router.request_lane(
        type: :inference, models: ['gemma-4-31b-it'], rng: rng
      )
      expect(result).to be_nil
    end
  end
end
