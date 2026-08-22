# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inventory::Discovery, :ssot_v3 do
  # M4: discovery no longer SELECTS a provider/instance/model — SSOT routing
  # (Router.next_lane) is the sole selection authority. Discovery answers two
  # read-only facts against the registry lanes (the same lanes the router
  # reads): model_available? and can_embed?.

  describe '.model_available?' do
    before do
      activate(provider_family: 'vllm', instance_id: 'apollo',
               drafts: [offering_draft(model: 'gemma-4-31b-it', supported: %i[chat])])
    end

    it 'reads from the registry lanes' do
      expect(described_class.model_available?('gemma-4-31b-it', provider: :vllm)).to be(true)
      expect(described_class.model_available?('gemma-4-31b-it', provider: :vllm, instance: :apollo)).to be(true)
      expect(described_class.model_available?('gemma-4-31b-it', provider: :vllm, instance: :other)).to be(false)
      expect(described_class.model_available?('missing-model', provider: :vllm)).to be(false)
    end

    it 'matches tagged variants by prefix' do
      activate(provider_family: 'ollama', instance_id: 'local',
               drafts: [offering_draft(model: 'llama3:8b', supported: %i[chat])])

      expect(described_class.model_available?('llama3', provider: :ollama)).to be(true)
      expect(described_class.model_available?('llama3:8b', provider: :ollama)).to be(true)
      expect(described_class.model_available?('llama3:70b', provider: :ollama)).to be(false)
    end
  end

  it 'model_size always returns nil after P3 (size_bytes not stored on lanes)' do
    expect(described_class.model_size('any-model', provider: :vllm)).to be_nil
  end

  describe '.can_embed?' do
    it 'is false when no embedding-type lane is in the registry' do
      activate(provider_family: 'ollama', instance_id: 'local',
               drafts: [offering_draft(model: 'gemma-4-31b-it', supported: %i[chat])])

      expect(described_class.can_embed?).to be false
    end

    it 'is true when an embedding-type lane is in the registry' do
      activate(provider_family: 'ollama', instance_id: 'apollo-embed',
               drafts: [offering_draft(model: 'mxbai-embed-large:latest', supported: %i[embed])])

      expect(described_class.can_embed?).to be true
    end

    it 'records no provider/model/instance state (selection is the router alone)' do
      expect(described_class.respond_to?(:embedding_provider)).to be false
      expect(described_class.respond_to?(:embedding_model)).to be false
      expect(described_class.respond_to?(:embedding_instance)).to be false
      expect(described_class.respond_to?(:embedding_fallback_chain)).to be false
    end
  end
end
