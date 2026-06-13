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
    Legion::LLM::Router.health_tracker.reset_all
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
      # Simulate cooldown expiry by forcing half_open state
      tracker.instance_variable_get(:@mutex).synchronize do
        key = tracker.send(:instance_key, :vllm, :h200)
        tracker.instance_variable_get(:@circuits)[key][:state] = :half_open
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

    it 'raises EscalationExhausted with no_available_provider on empty chain' do
      executor.instance_variable_set(:@escalation_chain, build_chain)

      expect { executor.call }.to raise_error(Legion::LLM::EscalationExhausted, /No available providers/)
    end
  end
end
