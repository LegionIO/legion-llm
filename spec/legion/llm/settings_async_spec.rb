# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Settings do
  describe '.default' do
    subject(:defaults) { described_class.default }

    it 'includes pipeline_async_post_steps key' do
      expect(defaults).to have_key(:pipeline_async_post_steps)
    end

    it 'sets pipeline_async_post_steps to true by default' do
      expect(defaults[:pipeline_async_post_steps]).to be(true)
    end
  end

  describe '.embedding_defaults' do
    subject(:embedding) { described_class.embedding_defaults }

    it 'does not include azure in provider_fallback' do
      expect(embedding[:provider_fallback]).not_to include('azure')
    end

    it 'includes ollama, bedrock, and openai in provider_fallback' do
      expect(embedding[:provider_fallback]).to include('ollama', 'bedrock', 'openai')
    end
  end
end
