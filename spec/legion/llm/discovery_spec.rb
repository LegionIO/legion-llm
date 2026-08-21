# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inventory::Discovery do
  before do
    described_class.reset!
    Legion::LLM::Call::Registry.reset!
  end

  it 'model_available? reads from the Inventory live store' do
    Legion::LLM::Inventory.write_lane(lane: {
                                        id:              'direct:vllm:apollo:inference:gemma-4-31b-it',
                                        tier:            :direct,
                                        provider_family: :vllm,
                                        instance_id:     :apollo,
                                        model:           'gemma-4-31b-it',
                                        type:            :inference,
                                        capabilities:    %i[chat streaming],
                                        limits:          {},
                                        enabled:         true,
                                        cost:            {}
                                      })

    expect(described_class.model_available?('gemma-4-31b-it', provider: :vllm)).to be(true)
    expect(described_class.model_available?('gemma-4-31b-it', provider: :vllm, instance: :apollo)).to be(true)
    expect(described_class.model_available?('gemma-4-31b-it', provider: :vllm, instance: :other)).to be(false)
    expect(described_class.model_available?('missing-model', provider: :vllm)).to be(false)
  end

  it 'model_size always returns nil after P3 (size_bytes not stored on lanes)' do
    expect(described_class.model_size('any-model', provider: :vllm)).to be_nil
  end

  # M4: discovery no longer SELECTS an embedding provider/instance/model —
  # SSOT :embed routing (Call::Embeddings → Router.next_lane) is the sole
  # selection authority. Discovery answers one capability fact: can_embed?
  # reads the live Inventory lane store (the same lanes the router reads).
  describe 'embedding capability detection (M4: no second selection domain)' do
    def seed_embedding_lane(provider, instance, model, tier: :local, capabilities: %i[embedding])
      Legion::LLM::Inventory.write_lane(lane: {
                                          id:              "#{tier}:#{provider}:#{instance}:embed:#{model.tr(':', '_')}",
                                          tier:            tier,
                                          provider_family: provider,
                                          instance_id:     instance,
                                          model:           model,
                                          type:            :embed,
                                          capabilities:    capabilities,
                                          limits:          {},
                                          enabled:         true,
                                          cost:            {}
                                        })
    end

    before { Legion::LLM::Inventory.reset_live_store! }
    after  { Legion::LLM::Inventory.reset_live_store! }

    it 'is false when no embedding-capable lane is in the Inventory store' do
      seed_embedding_lane(:ollama, :local, 'gemma-4-31b-it', capabilities: %i[chat streaming])
      expect(described_class.can_embed?).to be false
    end

    it 'is true when an embedding-capable lane is in the Inventory store' do
      seed_embedding_lane(:ollama, :'apollo-embed', 'mxbai-embed-large:latest', tier: :direct)
      expect(described_class.can_embed?).to be true
    end

    it 'records no provider/model/instance state (selection is the router alone)' do
      seed_embedding_lane(:ollama, :'apollo-embed', 'mxbai-embed-large:latest', tier: :direct)
      expect(described_class.respond_to?(:embedding_provider)).to be false
      expect(described_class.respond_to?(:embedding_model)).to be false
      expect(described_class.respond_to?(:embedding_instance)).to be false
      expect(described_class.respond_to?(:embedding_fallback_chain)).to be false
    end
  end

  describe 'health and loaded field preservation' do
    it 'preserves health metadata from offerings' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{ id: 'model-a', capabilities: %i[completion], health: { status: 'healthy', latency_ms: 42 } }]
      )

      entry = { provider: :vllm, instance: :apollo, adapter: adapter, metadata: {} }
      models = described_class.send(:fetch_offering_models, entry)

      expect(models.first[:health]).to eq({ status: 'healthy', latency_ms: 42 })
    end

    it 'preserves loaded: true from offering data' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{ id: 'model-a', capabilities: %i[completion], loaded: true }]
      )

      entry = { provider: :ollama, instance: :local, adapter: adapter, metadata: {} }
      models = described_class.send(:fetch_offering_models, entry)

      expect(models.first[:loaded]).to be(true)
    end

    it 'preserves loaded: false without losing it' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{ id: 'model-b', capabilities: %i[completion], loaded: false }]
      )

      entry = { provider: :ollama, instance: :local, adapter: adapter, metadata: {} }
      models = described_class.send(:fetch_offering_models, entry)

      expect(models.first[:loaded]).to be(false)
    end

    it 'extracts loaded from metadata when not at top level' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{ id: 'model-c', capabilities: %i[completion], metadata: { loaded: true } }]
      )

      entry = { provider: :ollama, instance: :local, adapter: adapter, metadata: {} }
      models = described_class.send(:fetch_offering_models, entry)

      expect(models.first[:loaded]).to be(true)
    end

    # SSOT v3: discovery no longer calls health_tracker. Healthy offerings record
    # :ok discovery status (not a health signal). Health metadata is preserved in
    # the returned offering hash for downstream informational use.
    it 'records :ok discovery status when offerings are returned successfully' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{ id: 'model-a', capabilities: %i[completion], health: { status: 'healthy' } }]
      )

      entry = { provider: :vllm, instance: :apollo, adapter: adapter, metadata: {} }
      described_class.send(:fetch_offering_models, entry)

      expect(described_class.discovery_status(provider: :vllm, instance: :apollo)).to eq(:ok)
    end

    # SSOT v3: an offering with health.status == 'unhealthy' does NOT trip a
    # circuit or set discovery status to :error. Health-based instance
    # unavailability is driven exclusively by Registry.dispatch_instance_unavailable
    # from the dispatcher layer — discovery only records :ok/:empty/:unreachable.
    it 'does not mark discovery status as :error for offerings with unhealthy health metadata' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{ id: 'model-a', capabilities: %i[completion], health: { status: 'unhealthy' } }]
      )

      entry = { provider: :vllm, instance: :apollo, adapter: adapter, metadata: {} }
      described_class.send(:fetch_offering_models, entry)

      status = described_class.discovery_status(provider: :vllm, instance: :apollo)
      expect(status).to eq(:ok)
      expect(status).not_to eq(:error)
    end

    # SSOT v3: latency_ms is preserved in the health field of the returned
    # offering data (for informational use). Discovery no longer dispatches a
    # separate :latency signal to any health tracker.
    it 'preserves latency_ms in the health field of the returned offering data' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{ id: 'model-a', capabilities: %i[completion], health: { status: 'healthy', latency_ms: 150 } }]
      )

      entry = { provider: :vllm, instance: :apollo, adapter: adapter, metadata: {} }
      models = described_class.send(:fetch_offering_models, entry)

      expect(models.first[:health]).to include(latency_ms: 150)
    end
  end

  describe 'capability_sources preservation' do
    it 'preserves capability_sources from offerings in fetch_offering_models' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{
          id:                 'test-model',
          capabilities:       %i[completion streaming tools],
          capability_sources: {
            streaming: { value: true, source: :instance_override },
            tools:     { value: true, source: :instance_override }
          }
        }]
      )

      entry = { provider: :vllm, instance: :apollo, adapter: adapter, metadata: {} }
      models = described_class.send(:fetch_offering_models, entry)

      expect(models.first[:capability_sources]).to eq(
        streaming: { value: true, source: :instance_override },
        tools:     { value: true, source: :instance_override }
      )
    end

    it 'does not blindly merge registry metadata capabilities when offering has capability_sources' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{
          id:                 'restricted-model',
          capabilities:       %i[completion],
          capability_sources: {
            tools:     { value: false, source: :default_false },
            streaming: { value: false, source: :default_false }
          }
        }]
      )

      entry = { provider: :vllm, instance: :apollo, adapter: adapter,
                metadata: { capabilities: %i[completion streaming tools] } }
      models = described_class.send(:fetch_offering_models, entry)

      expect(models.first[:capabilities]).to eq(%i[completion])
      expect(models.first[:capabilities]).not_to include(:tools)
      expect(models.first[:capabilities]).not_to include(:streaming)
    end

    it 'accepts live offering tools: true from :instance_override source' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{
          id:                 'tool-model',
          capabilities:       %i[completion streaming tools],
          capability_sources: {
            tools: { value: true, source: :instance_override }
          }
        }]
      )

      entry = { provider: :vllm, instance: :apollo, adapter: adapter, metadata: {} }
      models = described_class.send(:fetch_offering_models, entry)

      expect(models.first[:capabilities]).to include(:tools)
    end
  end
end
