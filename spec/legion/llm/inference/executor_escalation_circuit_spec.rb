# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor, 'escalation circuit guard' do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :vllm, model: 'qwen3:32b' }
    )
  end
  let(:executor) { described_class.new(request) }

  let(:vllm_resolution) do
    Legion::LLM::Router::Resolution.new(
      tier: :fleet, provider: :vllm, instance: :h200, model: 'qwen3:32b', offering_id: 'vllm-h200-qwen'
    )
  end
  let(:bedrock_resolution) do
    Legion::LLM::Router::Resolution.new(
      tier: :cloud, provider: :bedrock, instance: :primary, model: 'anthropic.claude-sonnet-4', offering_id: 'bedrock-sonnet'
    )
  end

  before do
    allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(true)
    allow(Legion::LLM::Audit).to receive(:emit_prompt)
    Legion::LLM::Router.reset!
    # Seed provider settings and Inventory lanes so HealthTracker circuit writes are visible
    # to circuit_open? (which now reads lane health, not HealthTracker directly — P2).
    Legion::Settings[:extensions][:llm][:vllm] ||= { weight: 100, instances: {}, models: {} }
    Legion::Settings[:extensions][:llm][:bedrock] ||= { weight: 100, instances: {}, models: {} }
    Legion::Settings[:extensions][:llm][:anthropic] ||= { weight: 100, instances: {}, models: {} }
    Legion::LLM::Inventory.write_lane(
      lane: { id: 'fleet:vllm:h200:inference:qwen3-32b', tier: :fleet, provider_family: :vllm,
              instance_id: :h200, model: 'qwen3-32b', type: :inference },
      ttl:  3600
    )
    Legion::LLM::Inventory.write_lane(
      lane: { id: 'cloud:bedrock:primary:inference:anthropic.claude-sonnet-4', tier: :cloud,
              provider_family: :bedrock, instance_id: :primary,
              model: 'anthropic.claude-sonnet-4', type: :inference },
      ttl:  3600
    )
    Legion::LLM::Inventory.write_lane(
      lane: { id: 'cloud:anthropic:primary:inference:claude-haiku-4-5', tier: :cloud,
              provider_family: :anthropic, instance_id: :primary,
              model: 'claude-haiku-4-5', type: :inference },
      ttl:  3600
    )
    Legion::LLM::Inventory.write_lane(
      lane: { id: 'cloud:anthropic:secondary:inference:claude-haiku-4-5', tier: :cloud,
              provider_family: :anthropic, instance_id: :secondary,
              model: 'claude-haiku-4-5', type: :inference },
      ttl:  3600
    )
  end

  def trip_circuit(provider:, instance:)
    tracker = Legion::LLM::Router.health_tracker
    4.times do
      tracker.report(provider: provider, instance: instance, signal: :error, value: 1)
    end
  end

  def build_chain(*resolutions)
    Legion::LLM::Router::EscalationChain.new(resolutions: resolutions, max_attempts: resolutions.size)
  end

  describe 'skipping open circuits' do
    it 'skips a resolution whose circuit is open and uses the next one' do
      trip_circuit(provider: :vllm, instance: :h200)

      executor.instance_variable_set(:@escalation_chain, build_chain(vllm_resolution, bedrock_resolution))

      bedrock_adapter = Module.new do
        define_singleton_method(:chat) { |**_| { content: 'from bedrock', usage: { input_tokens: 5, output_tokens: 3 } } }
      end
      Legion::LLM::Call::Registry.register(:bedrock, bedrock_adapter, instance: :primary)

      executor.call
      history = executor.instance_variable_get(:@escalation_history)
      expect(history.first[:outcome]).to eq(:skipped_open_circuit)
      expect(executor.instance_variable_get(:@resolved_provider)).to eq(:bedrock)
    end

    it 'allows half_open as a recovery probe' do
      tracker = Legion::LLM::Router.health_tracker
      trip_circuit(provider: :vllm, instance: :h200)
      # Simulate cooldown expiry by forcing half_open state in both breaker and Inventory lane
      # (P2: Inventory lane is the SSOT for health — circuit_open? reads from there)
      tracker.instance_variable_get(:@mutex).synchronize do
        key = tracker.send(:instance_key, :vllm, :h200)
        tracker.instance_variable_get(:@circuits)[key][:state] = :half_open
      end
      vllm_lane = Legion::LLM::Inventory.lane(id: 'fleet:vllm:h200:inference:qwen3-32b')
      if vllm_lane
        Legion::LLM::Inventory.write_lane(
          lane: vllm_lane, ttl: 3600,
          health: vllm_lane[:health].merge(circuit_state: :half_open, available: true)
        )
      end

      vllm_adapter = Module.new do
        define_singleton_method(:chat) { |**_| { content: 'from vllm', usage: { input_tokens: 5, output_tokens: 3 } } }
      end
      Legion::LLM::Call::Registry.register(:vllm, vllm_adapter, instance: :h200)

      executor.instance_variable_set(:@escalation_chain, build_chain(vllm_resolution, bedrock_resolution))
      executor.call

      expect(executor.instance_variable_get(:@resolved_provider)).to eq(:vllm)
    end

    it 'raises EscalationExhausted when all circuits are open' do
      trip_circuit(provider: :vllm, instance: :h200)
      trip_circuit(provider: :bedrock, instance: :primary)

      executor.instance_variable_set(:@escalation_chain, build_chain(vllm_resolution, bedrock_resolution))

      expect { executor.call }.to raise_error(Legion::LLM::EscalationExhausted)
    end

    it 'raises a routing error with no_available_provider on empty chain' do
      empty_chain = build_chain
      allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(false)
      allow(Legion::LLM::Router).to receive(:resolve_chain).and_return(empty_chain)
      allow(Legion::LLM::Router).to receive(:resolve).and_return(nil)
      allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return([])

      executor = described_class.new(request)
      executor.instance_variable_set(:@escalation_chain, empty_chain)

      expect { executor.call }.to raise_error do |error|
        expect(error).to be_a(Legion::LLM::EscalationExhausted)
                     .or be_a(Legion::LLM::RoutingFailedDependency)
      end
    end
  end

  describe 'failing over across instances of the same provider' do
    let(:anthropic_primary) do
      Legion::LLM::Router::Resolution.new(tier: :frontier, provider: :anthropic, instance: :primary, model: 'claude-haiku-4-5')
    end
    let(:anthropic_secondary) do
      Legion::LLM::Router::Resolution.new(tier: :frontier, provider: :anthropic, instance: :secondary, model: 'claude-haiku-4-5')
    end

    it 'tries a sibling instance after an account-scoped (credit) error rather than skipping the whole model' do
      # First account is out of credits; the second account serving the SAME model
      # must still be tried before the chain would cross to another provider.
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

      executor.instance_variable_set(:@escalation_chain, build_chain(anthropic_primary, anthropic_secondary))
      executor.call

      expect(executor.instance_variable_get(:@resolved_provider)).to eq(:anthropic)
      expect(executor.instance_variable_get(:@resolved_instance)).to eq(:secondary)
    end

    it 'deprioritizes the creditless instance (per-instance circuit) without denying the model or touching siblings' do
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

      executor.instance_variable_set(:@escalation_chain, build_chain(anthropic_primary, anthropic_secondary))
      executor.call

      # Creditless account's circuit is open (skipped on future requests); the healthy
      # sibling is untouched; the model is NOT denied (it works on the sibling).
      circuits = tracker.instance_variable_get(:@circuits)
      expect(circuits.dig('anthropic/primary', :state)).to eq(:open)
      expect(circuits.dig('anthropic/secondary', :state) || :closed).to eq(:closed)
      expect(tracker.model_denied?(provider: :anthropic, model: 'claude-haiku-4-5', instance: :primary)).to be(false)
    end
  end
end
