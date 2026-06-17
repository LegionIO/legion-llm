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

  let(:bedrock_offering) do
    {
      model:           'anthropic.claude-sonnet-4',
      provider_family: 'bedrock',
      instance_id:     'primary',
      capabilities:    %w[chat completion streaming tools],
      limits:          { context_window: 200_000 }
    }
  end

  let(:vllm_offering) do
    {
      model:           'qwen3:32b',
      provider_family: 'vllm',
      instance_id:     'h200',
      capabilities:    %w[chat completion streaming tools],
      limits:          { context_window: 32_768 }
    }
  end

  before do
    allow(Legion::LLM::Inventory).to receive(:offerings).and_call_original
    allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :bedrock)).and_return([bedrock_offering])
    allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :vllm)).and_return([vllm_offering])
    allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :ollama)).and_return([])
    allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :anthropic)).and_return([])
  end

  describe '.filter_resolutions' do
    it 'drops resolutions with open circuits' do
      4.times { Legion::LLM::Router.health_tracker.report(provider: :vllm, instance: :h200, signal: :error, value: 1) }

      filtered, reasons = described_class.filter_resolutions([vllm_resolution, bedrock_resolution])
      expect(filtered.map(&:provider)).to eq([:bedrock])
      expect(reasons).to include(hash_including(provider: :vllm, instance: :h200, reason: :circuit_open))
    end

    it 'keeps half-open circuits as recovery probes' do
      tracker = Legion::LLM::Router.health_tracker
      tracker.trip_circuit(provider: :vllm, instance: :h200, reason: 'test')
      tracker.instance_variable_get(:@mutex).synchronize do
        key = tracker.send(:instance_key, :vllm, :h200)
        tracker.instance_variable_get(:@circuits)[key][:state] = :half_open
      end

      filtered, _reasons = described_class.filter_resolutions([vllm_resolution, bedrock_resolution])
      expect(filtered.map(&:provider)).to include(:vllm)
    end

    it 'drops resolutions with denied models' do
      Legion::LLM::Router.health_tracker.deny_model(provider: :vllm, instance: :h200, model: 'qwen3:32b', reason: 'test')

      filtered, reasons = described_class.filter_resolutions([vllm_resolution, bedrock_resolution])
      expect(filtered.map(&:provider)).to eq([:bedrock])
      expect(reasons).to include(hash_including(provider: :vllm, model: 'qwen3:32b', reason: :model_denied))
    end

    it 'drops resolutions missing required capabilities' do
      ollama_offering = { model: 'phi:3b', provider_family: 'ollama', instance_id: 'local',
                          capabilities: %w[completion], limits: {} }
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :ollama)).and_return([ollama_offering])

      no_tools = Legion::LLM::Router::Resolution.new(
        tier: :local, provider: :ollama, instance: :local,
        model: 'phi:3b', metadata: { capabilities: %i[completion] }
      )

      filtered, reasons = described_class.filter_resolutions(
        [no_tools, bedrock_resolution],
        required_capabilities: [:tools]
      )
      expect(filtered.map(&:provider)).to eq([:bedrock])
      expect(reasons).to include(hash_including(provider: :ollama, reason: :missing_capability))
    end

    it 'returns empty array when all filtered' do
      Legion::LLM::Router.health_tracker.trip_circuit(provider: :vllm, instance: :h200, reason: 'test')
      Legion::LLM::Router.health_tracker.trip_circuit(provider: :bedrock, instance: :primary, reason: 'test')

      filtered, reasons = described_class.filter_resolutions([vllm_resolution, bedrock_resolution])
      expect(filtered).to be_empty
      expect(reasons.map { |r| r[:reason] }).to all(eq(:circuit_open))
    end

    it 'passes through when Inventory confirms models exist' do
      filtered, reasons = described_class.filter_resolutions([vllm_resolution, bedrock_resolution])
      expect(filtered.size).to eq(2)
      expect(reasons).to be_empty
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
      ollama_offering = { model: 'phi:3b', provider_family: 'ollama', instance_id: 'local',
                          capabilities: %w[completion], limits: {} }
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :ollama)).and_return([ollama_offering])

      no_tools_resolution = Legion::LLM::Router::Resolution.new(
        tier: :local, provider: :ollama, instance: :local,
        model: 'phi:3b', metadata: { capabilities: %i[completion] }
      )
      expect(described_class.rejection_reason(no_tools_resolution, estimated_tokens: nil, required_capabilities: [:tools])).to eq(:missing_capability)
    end

    it 'returns nil when all checks pass' do
      expect(described_class.rejection_reason(bedrock_resolution, estimated_tokens: nil, required_capabilities: [:tools])).to be_nil
    end

    it 'returns :missing_capability when Inventory offering has no tools capability' do
      ollama_offering = { model: 'phi:3b', provider_family: 'ollama', instance_id: 'local',
                          capabilities: %w[completion], limits: {} }
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :ollama)).and_return([ollama_offering])

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

    it 'does not reject cloud providers when discovery reports empty — Inventory is authoritative' do
      Legion::LLM::Discovery.record_discovery_status(provider: :bedrock, instance: :primary, status: :empty)

      reason = described_class.rejection_reason(
        bedrock_resolution,
        estimated_tokens:      nil,
        required_capabilities: [:tools]
      )

      expect(reason).to be_nil
    end

    it 'rejects discoverable providers when Inventory has no models' do
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :vllm)).and_return([])

      reason = described_class.rejection_reason(
        vllm_resolution,
        estimated_tokens:      nil,
        required_capabilities: []
      )

      expect(reason).to eq(:provider_instance_has_no_models)
    end

    it 'rejects discoverable providers when discovery is unreachable' do
      Legion::LLM::Discovery.record_discovery_status(provider: :vllm, instance: :h200, status: :unreachable)

      reason = described_class.rejection_reason(
        vllm_resolution,
        estimated_tokens:      nil,
        required_capabilities: []
      )
      expect(reason).to eq(:discovery_unavailable)
    end

    it 'does not reject cloud providers when discovery is unreachable' do
      Legion::LLM::Discovery.record_discovery_status(provider: :bedrock, instance: :primary, status: :unreachable)

      reason = described_class.rejection_reason(
        bedrock_resolution,
        estimated_tokens:      nil,
        required_capabilities: []
      )
      expect(reason).to be_nil
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

    it 'passes when Inventory confirms the model with matching capabilities' do
      vllm_tools_offering = vllm_offering.merge(model: 'test-model', capabilities: %w[completion streaming tools])
      allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :vllm)).and_return([vllm_tools_offering])

      confirmed_resolution = Legion::LLM::Router::Resolution.new(
        tier: :fleet, provider: :vllm, instance: :gpu1,
        model: 'test-model',
        metadata: { capabilities: %i[completion streaming tools] }
      )

      reason = described_class.rejection_reason(
        confirmed_resolution,
        estimated_tokens:      nil,
        required_capabilities: [:tools]
      )
      expect(reason).to be_nil
    end

    it 'returns :model_not_offered when Inventory has models but not the requested one' do
      reason = described_class.rejection_reason(
        Legion::LLM::Router::Resolution.new(
          tier: :fleet, provider: :vllm, instance: :h200,
          model: 'nonexistent-model', metadata: {}
        ),
        estimated_tokens:      nil,
        required_capabilities: []
      )
      expect(reason).to eq(:model_not_offered)
    end

    it 'returns :context_too_small when estimated tokens exceed context window' do
      reason = described_class.rejection_reason(
        vllm_resolution,
        estimated_tokens:      31_000,
        required_capabilities: []
      )
      expect(reason).to eq(:context_too_small)
    end

    # Regression: a cloud/frontier provider paired with a model from a different
    # family (the anthropic->qwen e2e failure). Inventory knows anthropic offers
    # only haiku, so a qwen model for anthropic must be rejected — the daemon never
    # dispatches a (provider, model) the live catalog does not list, for ANY tier.
    context 'when a cloud provider is paired with a foreign model not in its catalog' do
      let(:anthropic_offering) do
        {
          model:           'claude-haiku-4-5-20251001',
          provider_family: 'anthropic',
          instance_id:     'primary',
          capabilities:    %w[completion streaming tools],
          limits:          { context_window: 200_000 }
        }
      end

      before do
        allow(Legion::LLM::Inventory).to receive(:offerings)
          .with(hash_including(provider: :anthropic)).and_return([anthropic_offering])
      end

      it 'rejects anthropic + a qwen model as :model_not_offered' do
        reason = described_class.rejection_reason(
          Legion::LLM::Router::Resolution.new(
            tier: :frontier, provider: :anthropic, instance: :primary,
            model: 'qwen3.6-27b', metadata: {}
          ),
          estimated_tokens: nil, required_capabilities: []
        )
        expect(reason).to eq(:model_not_offered)
      end

      it 'allows anthropic + its own offered model' do
        reason = described_class.rejection_reason(
          Legion::LLM::Router::Resolution.new(
            tier: :frontier, provider: :anthropic, instance: :primary,
            model: 'claude-haiku-4-5-20251001', metadata: {}
          ),
          estimated_tokens: nil, required_capabilities: []
        )
        expect(reason).to be_nil
      end
    end

    it 'is permissive when Inventory lookup fails (inner rescue swallows offerings errors)' do
      allow(Legion::LLM::Inventory).to receive(:offerings).and_raise(StandardError, 'boom')

      reason = described_class.rejection_reason(
        bedrock_resolution,
        estimated_tokens:      nil,
        required_capabilities: []
      )
      expect(reason).to be_nil
    end

    it 'returns :availability_check_error when an availability check raises unexpectedly' do
      allow(described_class).to receive(:discovery_status_for).and_raise(StandardError, 'boom')

      reason = described_class.rejection_reason(
        bedrock_resolution,
        estimated_tokens:      nil,
        required_capabilities: []
      )
      expect(reason).to eq(:availability_check_error)
    end
  end
end
