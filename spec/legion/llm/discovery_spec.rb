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

  describe 'embedding instance selection from registry' do
    def embedding_adapter(*model_names)
      offerings = model_names.map do |name|
        { model: name, capabilities: %i[embedding], size_bytes: 669_000_000 }
      end
      Class.new do
        define_method(:offerings) { |live: false| live ? offerings : [] }
      end.new
    end

    def register_embedding_instance(provider, instance, tier, *model_names, default_model: nil)
      metadata = { tier: tier, capabilities: %i[embedding] }
      metadata[:default_model] = default_model if default_model
      Legion::LLM::Call::Registry.register(
        provider, embedding_adapter(*model_names), instance: instance, metadata: metadata
      )
    end

    def seed_embedding_lane(provider, instance, model, tier: :local)
      Legion::LLM::Inventory.write_lane(lane: {
                                          id:              "#{tier}:#{provider}:#{instance}:embed:#{model.tr(':', '_')}",
                                          tier:            tier,
                                          provider_family: provider,
                                          instance_id:     instance,
                                          model:           model,
                                          type:            :embed,
                                          capabilities:    %i[embedding],
                                          limits:          {},
                                          enabled:         true,
                                          cost:            {}
                                        })
    end

    after { Legion::Settings.reset! }

    it 'honors an explicitly configured embedding instance over a higher-tier-ranked empty instance' do
      register_embedding_instance(:ollama, :local, :local)
      register_embedding_instance(:ollama, :'apollo-embed', :direct, 'mxbai-embed-large:latest')
      seed_embedding_lane(:ollama, :'apollo-embed', 'mxbai-embed-large:latest', tier: :direct)

      Legion::Settings[:llm][:embedding] = {
        provider: 'ollama', instance: 'apollo-embed', default_model: 'mxbai-embed-large:latest'
      }

      described_class.detect_embedding_capability

      expect(described_class.can_embed?).to be true
      expect(described_class.embedding_instance).to eq(:'apollo-embed')
      expect(described_class.embedding_provider).to eq(:ollama)
      expect(described_class.embedding_model).to eq('mxbai-embed-large:latest')
    end

    it 'honors an explicitly configured instance even with a symbol-keyed embedding settings hash' do
      register_embedding_instance(:ollama, :local, :local)
      register_embedding_instance(:ollama, :'apollo-embed', :direct, 'mxbai-embed-large:latest')
      seed_embedding_lane(:ollama, :'apollo-embed', 'mxbai-embed-large:latest', tier: :direct)

      Legion::Settings[:llm][:embedding] = {
        instance: :'apollo-embed', default_model: 'mxbai-embed-large:latest'
      }

      described_class.detect_embedding_capability

      expect(described_class.embedding_instance).to eq(:'apollo-embed')
    end

    it 'does not select a higher-ranked instance that lacks the model when another instance has it' do
      register_embedding_instance(:ollama, :local, :local)
      register_embedding_instance(:ollama, :'apollo-embed', :direct, 'mxbai-embed-large:latest',
                                  default_model: 'mxbai-embed-large:latest')
      seed_embedding_lane(:ollama, :'apollo-embed', 'mxbai-embed-large:latest', tier: :direct)

      described_class.detect_embedding_capability

      expect(described_class.can_embed?).to be true
      expect(described_class.embedding_instance).to eq(:'apollo-embed')
      expect(described_class.embedding_model).to eq('mxbai-embed-large:latest')
    end

    it 'still prefers a local instance when it genuinely has the model and no pin is configured' do
      register_embedding_instance(:ollama, :local, :local, 'mxbai-embed-large:latest',
                                  default_model: 'mxbai-embed-large:latest')
      register_embedding_instance(:ollama, :'apollo-embed', :direct, 'mxbai-embed-large:latest',
                                  default_model: 'mxbai-embed-large:latest')
      seed_embedding_lane(:ollama, :local, 'mxbai-embed-large:latest', tier: :local)
      seed_embedding_lane(:ollama, :'apollo-embed', 'mxbai-embed-large:latest', tier: :direct)

      described_class.detect_embedding_capability

      expect(described_class.embedding_instance).to eq(:local)
    end
  end

  describe 'health and loaded field preservation' do
    before { Legion::LLM::Router.reset! }

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

    it 'reports :success signal to health tracker for healthy offerings' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{ id: 'model-a', capabilities: %i[completion], health: { status: 'healthy' } }]
      )

      entry = { provider: :vllm, instance: :apollo, adapter: adapter, metadata: {} }
      expect(Legion::LLM::Router.health_tracker).to receive(:report).with(
        hash_including(provider: :vllm, instance: :apollo, signal: :success)
      )

      described_class.send(:fetch_offering_models, entry)
    end

    it 'reports :error signal for unhealthy offerings' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{ id: 'model-a', capabilities: %i[completion], health: { status: 'unhealthy' } }]
      )

      entry = { provider: :vllm, instance: :apollo, adapter: adapter, metadata: {} }
      expect(Legion::LLM::Router.health_tracker).to receive(:report).with(
        hash_including(provider: :vllm, instance: :apollo, signal: :error)
      )

      described_class.send(:fetch_offering_models, entry)
    end

    it 'reports :latency signal when latency_ms is present' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{ id: 'model-a', capabilities: %i[completion], health: { status: 'healthy', latency_ms: 150 } }]
      )

      entry = { provider: :vllm, instance: :apollo, adapter: adapter, metadata: {} }
      expect(Legion::LLM::Router.health_tracker).to receive(:report).with(
        hash_including(signal: :success)
      )
      expect(Legion::LLM::Router.health_tracker).to receive(:report).with(
        hash_including(signal: :latency, value: 150)
      )

      described_class.send(:fetch_offering_models, entry)
    end
  end

  describe 'loaded_model_bonus reachability' do
    before do
      Legion::LLM::Router.reset!
      allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
      allow(described_class).to receive(:model_available?).and_return(true)
      allow(described_class).to receive(:model_size).and_return(nil)
      allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(65_536)
    end

    it 'gives loaded models a scoring bonus in generated rules' do
      discovered = {
        ollama: {
          local: {
            models:       [
              { name: 'qwen3:7b', capabilities: %i[completion streaming tools], loaded: true },
              { name: 'llama3:8b', capabilities: %i[completion streaming tools], loaded: false }
            ],
            capabilities: %i[completion streaming tools]
          }
        }
      }

      rules = Legion::LLM::Discovery::RuleGenerator.generate(discovered)
      qwen_rule = rules.find { |r| r[:name].include?('qwen3:7b') && r[:when][:operation] == :chat }
      llama_rule = rules.find { |r| r[:name].include?('llama3:8b') && r[:when][:operation] == :chat }

      expect(qwen_rule[:then][:loaded]).to be(true)
      expect(llama_rule[:then][:loaded]).to be(false)
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
