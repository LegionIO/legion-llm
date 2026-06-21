# frozen_string_literal: true

require 'spec_helper'

# P5: Executor circuit-guard tests migrated to use Inventory lanes + HealthTracker writes.
# The old @escalation_chain ivar approach is replaced by the while remaining.positive? loop
# that calls Router.request_lane → which reads lane health from Inventory (P2 SSOT).
RSpec.describe Legion::LLM::Inference::Executor, 'escalation circuit guard' do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :vllm, model: 'qwen3:32b' }
    )
  end
  let(:executor) { described_class.new(request) }

  before do
    allow(Legion::LLM::Audit).to receive(:emit_prompt)
    Legion::LLM::Router.reset!
    Legion::Settings[:extensions][:llm][:vllm]    ||= { weight: 100, instances: {}, models: {} }
    Legion::Settings[:extensions][:llm][:bedrock] ||= { weight: 100, instances: {}, models: {} }
    Legion::Settings[:extensions][:llm][:anthropic] ||= { weight: 100, instances: {}, models: {} }
    # Write Inventory lanes — HealthTracker writes update these, request_lane reads them.
    write_test_lane(provider: :vllm,     instance: :h200,      model: 'qwen3-32b',
                    tier: :fleet,     lane_weight: 100_000_000)
    write_test_lane(provider: :bedrock,  instance: :primary,   model: 'anthropic.claude-sonnet-4',
                    tier: :cloud,     lane_weight: 90_000_000)
    write_test_lane(provider: :anthropic, instance: :primary,  model: 'claude-haiku-4-5',
                    tier: :frontier,  lane_weight: 80_000_000)
    write_test_lane(provider: :anthropic, instance: :secondary, model: 'claude-haiku-4-5',
                    tier: :frontier,  lane_weight: 80_000_000)

    Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = true
  end

  def trip_circuit(provider:, instance:)
    tracker = Legion::LLM::Router.health_tracker
    4.times do
      tracker.report(provider: provider, instance: instance, signal: :error, value: 1)
    end
  end

  describe 'skipping open circuits' do
    it 'skips a lane whose circuit is open and uses the next highest-weight lane' do
      trip_circuit(provider: :vllm, instance: :h200)

      # P5: add bedrock lane with the same model so request_lane can find it after vllm is tripped
      write_test_lane(provider: :bedrock, instance: :primary, model: 'qwen3-32b', tier: :cloud,
                      lane_weight: 90_000_000)
      bedrock_adapter = Module.new do
        define_singleton_method(:chat) { |**_| { content: 'from bedrock', usage: { input_tokens: 5, output_tokens: 3 } } }
      end
      Legion::LLM::Call::Registry.register(:bedrock, bedrock_adapter, instance: :primary)

      executor.call
      expect(executor.instance_variable_get(:@resolved_provider)).to eq(:bedrock)
    end

    it 'allows half_open lane as a recovery probe' do
      trip_circuit(provider: :vllm, instance: :h200)
      # Force vllm lane to half_open via direct lane update (simulating cooldown expiry)
      vllm_lane = Legion::LLM::Inventory.lane(id: 'fleet:vllm:h200:inference:qwen3-32b')
      if vllm_lane
        Legion::LLM::Inventory.write_lane(
          lane:   vllm_lane.merge(lane_weight: 50_000_000),
          ttl:    3600,
          health: vllm_lane[:health].merge(circuit_state: :half_open, available: true)
        )
      end

      vllm_adapter = Module.new do
        define_singleton_method(:chat) { |**_| { content: 'from vllm', usage: { input_tokens: 5, output_tokens: 3 } } }
      end
      Legion::LLM::Call::Registry.register(:vllm, vllm_adapter, instance: :h200)

      executor.call
      expect(executor.instance_variable_get(:@resolved_provider)).to eq(:vllm)
    end

    it 'raises when all circuit lanes are open (no eligible lanes → EscalationExhausted or NoLaneAvailable)' do
      trip_circuit(provider: :vllm, instance: :h200)
      trip_circuit(provider: :bedrock, instance: :primary)
      trip_circuit(provider: :anthropic, instance: :primary)
      trip_circuit(provider: :anthropic, instance: :secondary)

      expect { executor.call }.to raise_error do |error|
        expect(error).to be_a(Legion::LLM::Errors::EscalationExhausted)
                     .or be_a(Legion::LLM::Errors::NoLaneAvailable)
                     .or be_a(Legion::LLM::EscalationExhausted)
      end
    end

    it 'raises a routing error when Inventory is empty' do
      Legion::LLM::Inventory.reset_live_store!

      expect { executor.call }.to raise_error do |error|
        expect(error).to be_a(Legion::LLM::Errors::NoLaneAvailable)
                     .or be_a(Legion::LLM::EscalationExhausted)
                     .or be_a(Legion::LLM::RoutingFailedDependency)
      end
    end
  end

  describe 'failing over across instances of the same provider' do
    before do
      # P5: reset Inventory AND Router so ONLY anthropic lanes exist — prevents vllm/bedrock
      # from being dispatched first, and clears any circuit state from previous tests.
      # Use 'qwen3:32b' (colon) to match the request's routing model exactly.
      Legion::LLM::Router.reset!
      Legion::LLM::Inventory.reset_live_store!
      # Give primary a higher weight so it's ALWAYS dispatched first.
      # This ensures the credit-failure triggers on primary, not secondary.
      Legion::Settings[:extensions][:llm][:anthropic] ||= {}
      Legion::Settings[:extensions][:llm][:anthropic][:instances] = {
        primary:   { weight: 200 },
        secondary: { weight: 100 }
      }
      write_test_lane(provider: :anthropic, instance: :primary,   model: 'qwen3:32b', tier: :frontier)
      write_test_lane(provider: :anthropic, instance: :secondary, model: 'qwen3:32b', tier: :frontier)
    end

    it 'tries a sibling instance after an account-scoped (credit) error' do
      primary = Module.new do
        define_singleton_method(:chat) do |**_|
          raise Legion::LLM::ProviderError, 'Your credit balance is too low to access the Anthropic API'
        end
      end
      secondary = Module.new do
        define_singleton_method(:chat) { |**_| { content: 'from the second account', usage: { input_tokens: 5, output_tokens: 3 } } }
      end
      Legion::LLM::Call::Registry.register(:anthropic, primary, instance: :primary)
      Legion::LLM::Call::Registry.register(:anthropic, secondary, instance: :secondary)

      executor.call

      expect(executor.instance_variable_get(:@resolved_provider)).to eq(:anthropic)
      expect(executor.instance_variable_get(:@resolved_instance)).to eq(:secondary)
    end

    it 'deprioritizes the creditless instance circuit without denying the model or touching siblings' do
      tracker = Legion::LLM::Router.health_tracker
      primary = Module.new do
        define_singleton_method(:chat) do |**_|
          raise Legion::LLM::ProviderError, 'Your credit balance is too low to access the Anthropic API'
        end
      end
      secondary = Module.new do
        define_singleton_method(:chat) { |**_| { content: 'from the second account', usage: { input_tokens: 5, output_tokens: 3 } } }
      end
      Legion::LLM::Call::Registry.register(:anthropic, primary, instance: :primary)
      Legion::LLM::Call::Registry.register(:anthropic, secondary, instance: :secondary)

      executor.call

      circuits = tracker.instance_variable_get(:@circuits)
      expect(circuits.dig('anthropic/primary', :state)).to eq(:open)
      expect(circuits.dig('anthropic/secondary', :state)).not_to eq(:open)
    end
  end
end
