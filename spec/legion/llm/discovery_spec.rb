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
end
