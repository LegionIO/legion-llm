# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Router::Availability do
  before do
    Legion::LLM::Router.health_tracker.reset_all
    Legion::LLM::Discovery.reset!
  end

  let(:vllm_resolution) do
    Legion::LLM::Router::Resolution.new(
      tier: :fleet, provider: :vllm, instance: :h200,
      model: 'qwen3:32b', offering_id: 'vllm-h200-qwen',
      metadata: { capabilities: %i[completion streaming tools] }
    )
  end

  let(:bedrock_resolution) do
    Legion::LLM::Router::Resolution.new(
      tier: :cloud, provider: :bedrock, instance: :primary,
      model: 'anthropic.claude-sonnet-4', offering_id: 'bedrock-sonnet',
      metadata: { capabilities: %i[completion streaming tools] }
    )
  end

  describe '.filter_resolutions' do
    it 'drops resolutions with open circuits' do
      4.times { Legion::LLM::Router.health_tracker.report(provider: :vllm, instance: :h200, signal: :error, value: 1) }

      result = described_class.filter_resolutions([vllm_resolution, bedrock_resolution])
      expect(result.map(&:provider)).to eq([:bedrock])
    end

    it 'keeps half-open circuits as recovery probes' do
      tracker = Legion::LLM::Router.health_tracker
      tracker.trip_circuit(provider: :vllm, instance: :h200, reason: 'test')
      tracker.instance_variable_get(:@mutex).synchronize do
        key = tracker.send(:instance_key, :vllm, :h200)
        tracker.instance_variable_get(:@circuits)[key][:state] = :half_open
      end

      result = described_class.filter_resolutions([vllm_resolution, bedrock_resolution])
      expect(result.map(&:provider)).to include(:vllm)
    end

    it 'drops resolutions with denied models' do
      Legion::LLM::Router.health_tracker.deny_model(provider: :vllm, instance: :h200, model: 'qwen3:32b', reason: 'test')

      result = described_class.filter_resolutions([vllm_resolution, bedrock_resolution])
      expect(result.map(&:provider)).to eq([:bedrock])
    end

    it 'drops resolutions missing required capabilities' do
      no_tools = Legion::LLM::Router::Resolution.new(
        tier: :local, provider: :ollama, instance: :local,
        model: 'phi:3b', metadata: { capabilities: %i[completion] }
      )

      result = described_class.filter_resolutions(
        [no_tools, bedrock_resolution],
        required_capabilities: [:tools]
      )
      expect(result.map(&:provider)).to eq([:bedrock])
    end

    it 'returns empty array when all filtered' do
      Legion::LLM::Router.health_tracker.trip_circuit(provider: :vllm, instance: :h200, reason: 'test')
      Legion::LLM::Router.health_tracker.trip_circuit(provider: :bedrock, instance: :primary, reason: 'test')

      result = described_class.filter_resolutions([vllm_resolution, bedrock_resolution])
      expect(result).to be_empty
    end

    it 'passes through when discovery has not run (unknown status)' do
      result = described_class.filter_resolutions([vllm_resolution, bedrock_resolution])
      expect(result.size).to eq(2)
    end
  end

  describe '.rejection_reason' do
    it 'returns :circuit_open for open circuits' do
      Legion::LLM::Router.health_tracker.trip_circuit(provider: :vllm, instance: :h200, reason: 'test')
      expect(described_class.rejection_reason(vllm_resolution, estimated_tokens: nil, required_capabilities: [])).to eq(:circuit_open)
    end

    it 'returns :model_denied for denied models' do
      Legion::LLM::Router.health_tracker.deny_model(provider: :vllm, instance: :h200, model: 'qwen3:32b', reason: 'test')
      expect(described_class.rejection_reason(vllm_resolution, estimated_tokens: nil, required_capabilities: [])).to eq(:model_denied)
    end

    it 'returns :missing_capability when capabilities do not match' do
      no_tools_resolution = Legion::LLM::Router::Resolution.new(
        tier: :local, provider: :ollama, instance: :local,
        model: 'phi:3b', metadata: { capabilities: %i[completion] }
      )
      expect(described_class.rejection_reason(no_tools_resolution, estimated_tokens: nil, required_capabilities: [:tools])).to eq(:missing_capability)
    end

    it 'returns nil when all checks pass' do
      expect(described_class.rejection_reason(bedrock_resolution, estimated_tokens: nil, required_capabilities: [:tools])).to be_nil
    end

    it 'returns :missing_capability when capabilities are empty and discovery is :ok' do
      Legion::LLM::Discovery.record_discovery_status(provider: :ollama, instance: :local, status: :ok)
      allow(Legion::LLM::Discovery).to receive(:cached_discovered_models).and_return(
        [{ provider: :ollama, instance: :local, model: 'phi:3b', capabilities: [] }]
      )

      empty_caps_resolution = Legion::LLM::Router::Resolution.new(
        tier: :local, provider: :ollama, instance: :local,
        model: 'phi:3b', metadata: {}
      )

      reason = described_class.rejection_reason(
        empty_caps_resolution,
        estimated_tokens:      nil,
        required_capabilities: [:tools]
      )
      expect(reason).to eq(:missing_capability)
    end

    it 'returns :capability_unconfirmed when discovery is :unknown and source data denies required cap' do
      unconfirmed_resolution = Legion::LLM::Router::Resolution.new(
        tier: :fleet, provider: :vllm, instance: :gpu1,
        model: 'test-model',
        metadata: {
          capability_sources: {
            tools: { value: false, source: :default_false }
          }
        }
      )

      reason = described_class.rejection_reason(
        unconfirmed_resolution,
        estimated_tokens:      nil,
        required_capabilities: [:tools]
      )
      expect(reason).to eq(:capability_unconfirmed)
    end

    it 'returns :instance_unresolved when instance is nil and provider has multiple discovered instances' do
      Legion::LLM::Discovery.record_discovery_status(provider: :ollama, instance: nil, status: :ok)
      allow(Legion::LLM::Discovery).to receive(:cached_discovered_models).and_return(
        [
          { provider: :ollama, instance: :local, model: 'llama3', capabilities: %i[completion] },
          { provider: :ollama, instance: :remote, model: 'llama3', capabilities: %i[completion] }
        ]
      )

      nil_instance_resolution = Legion::LLM::Router::Resolution.new(
        tier: :local, provider: :ollama, instance: nil,
        model: 'llama3', metadata: {}
      )

      reason = described_class.rejection_reason(
        nil_instance_resolution,
        estimated_tokens:      nil,
        required_capabilities: []
      )
      expect(reason).to eq(:instance_unresolved)
    end

    it 'passes when capabilities confirmed from :instance_override source during cold boot' do
      confirmed_resolution = Legion::LLM::Router::Resolution.new(
        tier: :fleet, provider: :vllm, instance: :gpu1,
        model: 'test-model',
        metadata: {
          capabilities:       %i[completion streaming tools],
          capability_sources: {
            tools: { value: true, source: :instance_override }
          }
        }
      )

      reason = described_class.rejection_reason(
        confirmed_resolution,
        estimated_tokens:      nil,
        required_capabilities: [:tools]
      )
      expect(reason).to be_nil
    end
  end
end
