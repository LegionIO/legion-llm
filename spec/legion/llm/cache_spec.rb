# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'
require 'legion/llm/cache'

RSpec.describe Legion::LLM::Cache do
  before(:each) do
    Legion::Cache.setup
    Legion::Settings[:llm][:prompt_caching] = {
      enabled:        true,
      min_tokens:     1024,
      response_cache: { enabled: true, ttl_seconds: 300 }
    }
  end

  describe '.enabled?' do
    it 'returns true when cache is connected and settings enabled' do
      expect(described_class.enabled?).to be true
    end

    it 'returns false when response_cache is disabled in settings' do
      Legion::Settings[:llm][:prompt_caching] = { response_cache: { enabled: false } }
      expect(described_class.enabled?).to be false
    end
  end

  # M2: the pre-routing legacy key (Cache.key) is deleted — the response
  # cache is keyed by the exact Selection identity (.selection_key) only.

  describe '.get' do
    it 'returns nil on a cache miss' do
      expect(described_class.get('nonexistent_key')).to be_nil
    end

    it 'returns the stored response on a cache hit' do
      cache_key = 'test_hit_key'
      described_class.set(cache_key, { content: 'hello' })
      result = described_class.get(cache_key)
      expect(result).to be_a(Hash)
      expect(result[:content]).to eq('hello')
    end

    it 'returns symbolized keys' do
      cache_key = 'sym_key'
      described_class.set(cache_key, { 'content' => 'world' })
      result = described_class.get(cache_key)
      expect(result).to have_key(:content)
    end
  end

  describe '.set' do
    it 'returns true on success' do
      expect(described_class.set('key', { ok: true })).to be true
    end

    it 'stores the response so .get retrieves it' do
      described_class.set('store_key', { data: 1 })
      expect(described_class.get('store_key')).to include(data: 1)
    end

    it 'accepts a custom TTL' do
      expect { described_class.set('ttl_key', { x: 1 }, ttl: 60) }.not_to raise_error
    end
  end

  describe 'RESPONSE_CACHE_SCHEMA_VERSION' do
    it 'is set to 2' do
      expect(described_class::RESPONSE_CACHE_SCHEMA_VERSION).to eq(2)
    end

    it 'includes the schema version in deterministic keys' do
      base = {
        provider_family: :vllm, model: 'gemma4', revision: 'rev-1', operation: :chat,
        system: 'be helpful', messages: [{ role: 'user', content: 'hi' }]
      }
      key_v2 = described_class.selection_key(**base)

      stub_const('Legion::LLM::Cache::RESPONSE_CACHE_SCHEMA_VERSION', 3)

      key_v3 = described_class.selection_key(**base)
      expect(key_v3).not_to eq(key_v2)
    end
  end
end
