# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Discovery do
  before do
    described_class.reset!
    Legion::LLM::Call::Registry.reset!
  end

  it 'normalizes lex-llm ModelOffering objects from registry adapters' do
    offering = Legion::Extensions::Llm::Routing::ModelOffering.new(
      provider_family: :vllm,
      instance_id:     :apollo,
      tier:            :direct,
      model:           'qwen3.6-27b',
      usage_type:      :inference,
      capabilities:    %i[chat streaming],
      limits:          { context_window: 131_072 },
      metadata:        { parameter_count: 27_000_000_000 }
    )
    adapter = Class.new do
      define_method(:offerings) { |live: false| live ? [offering] : [] }
    end.new

    Legion::LLM::Call::Registry.register(:vllm, adapter, instance: :apollo, metadata: { tier: :direct })

    discovered = described_class.discovered_models

    expect(discovered).to contain_exactly(
      include(
        model:           'qwen3.6-27b',
        provider:        :vllm,
        instance:        :apollo,
        tier:            :direct,
        capabilities:    %i[chat streaming],
        context_length:  131_072,
        parameter_count: 27_000_000_000
      )
    )
  end

  it 'normalizes string provider instances from adapter offerings to symbols' do
    adapter = Class.new do
      def offerings(live: false)
        return [] unless live

        [
          {
            model:             'gpt4o-prod',
            provider_instance: 'eastus',
            capabilities:      %i[chat],
            size_bytes:        1_024
          }
        ]
      end
    end.new

    Legion::LLM::Call::Registry.register(:azure_foundry, adapter, instance: :default)

    discovered = described_class.discovered_models

    expect(discovered.first[:instance]).to eq(:eastus)
    expect(described_class.model_available?('gpt4o-prod', provider: :azure_foundry, instance: :eastus)).to be true
    expect(described_class.model_size('gpt4o-prod', provider: :azure_foundry, instance: :eastus)).to eq(1_024)
  end

  describe 'embedding instance selection from registry' do
    # Builds an adapter whose live offerings advertise the given embedding models. An empty
    # list models an instance that is registered and embedding-capable but has no model pulled.
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

    after { Legion::Settings.reset! }

    it 'honors an explicitly configured embedding instance over a higher-tier-ranked empty instance' do
      # local ranks first by tier but is empty; the configured direct-tier mesh instance has the model.
      register_embedding_instance(:ollama, :local, :local) # empty
      register_embedding_instance(:ollama, :'apollo-embed', :direct, 'mxbai-embed-large:latest')

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

      Legion::Settings[:llm][:embedding] = {
        instance: :'apollo-embed', default_model: 'mxbai-embed-large:latest'
      }

      described_class.detect_embedding_capability

      expect(described_class.embedding_instance).to eq(:'apollo-embed')
    end

    it 'does not select a higher-ranked instance that lacks the model when another instance has it' do
      # No pin configured: local ranks first but is empty, so it must be skipped in favor of the
      # mesh instance that actually serves the model.
      register_embedding_instance(:ollama, :local, :local) # empty
      register_embedding_instance(:ollama, :'apollo-embed', :direct, 'mxbai-embed-large:latest',
                                  default_model: 'mxbai-embed-large:latest')

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

      described_class.detect_embedding_capability

      expect(described_class.embedding_instance).to eq(:local)
    end
  end

  describe 'DISCOVERED_MODELS_SCHEMA_VERSION' do
    it 'is set to 3' do
      expect(described_class::DISCOVERED_MODELS_SCHEMA_VERSION).to eq(3)
    end

    it 'rejects stale discovered model entries with an older schema version' do
      described_class.instance_variable_set(
        :@discovered_models_cache,
        [
          {
            schema_version: 1,
            provider:       :vllm,
            instance:       :apollo,
            model:          'old-shape',
            capabilities:   %i[completion]
          }
        ]
      )

      expect(described_class.cached_discovered_models).to eq([])
    end

    it 'returns entries with the current schema version' do
      described_class.instance_variable_set(
        :@discovered_models_cache,
        [
          {
            schema_version: described_class::DISCOVERED_MODELS_SCHEMA_VERSION,
            provider:       :vllm,
            instance:       :apollo,
            model:          'legion-code-27b-v1',
            capabilities:   %i[completion streaming tools]
          }
        ]
      )

      expect(described_class.cached_discovered_models.size).to eq(1)
    end

    it 'stamps new offerings with the current schema version' do
      adapter = instance_double('Adapter')
      allow(adapter).to receive(:offerings).with(live: true).and_return(
        [{ id: 'test-model', capabilities: %i[completion] }]
      )

      entry = { provider: :vllm, instance: :default, adapter: adapter, metadata: {} }
      models = described_class.send(:fetch_offering_models, entry)

      expect(models.first[:schema_version]).to eq(described_class::DISCOVERED_MODELS_SCHEMA_VERSION)
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
    it 'preserves capability_sources from offerings in discovered model entries' do
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

      # Registry metadata claims tools capability — must NOT override the offering
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

    it 'includes capability_sources in normalize_model_for_rules output' do
      model_entry = {
        model:              'test-model',
        provider:           :vllm,
        instance:           :apollo,
        capabilities:       %i[completion tools],
        capability_sources: { tools: { value: true, source: :instance_override } }
      }
      result = described_class.send(:normalize_model_for_rules, model_entry)
      expect(result['capability_sources']).to eq(tools: { value: true, source: :instance_override })
    end
  end
end
