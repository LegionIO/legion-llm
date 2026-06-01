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
end
