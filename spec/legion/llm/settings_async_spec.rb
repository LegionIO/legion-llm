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

    # M4: the second selection domain (provider_fallback / provider_models /
    # ollama_preferred / pin keys) is gone — SSOT :embed routing is the sole
    # selection authority, so no provider-fallback order lives in settings.
    it 'carries no provider_fallback (selection is the router alone)' do
      expect(embedding).not_to have_key(:provider_fallback)
      expect(embedding).not_to have_key(:provider_models)
      expect(embedding).not_to have_key(:ollama_preferred)
    end
  end
end
