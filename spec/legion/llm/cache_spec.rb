# frozen_string_literal: true

require 'spec_helper'

# Stub Legion::Cache with an in-memory hash for testing
module Legion
  module Cache
    class << self
      def reset!
        @store = {}
      end

      def get(key)
        @store ||= {}
        @store[key]
      end

      def set(key, value, _ttl = 300)
        @store ||= {}
        @store[key] = value
        true
      end

      def delete(key)
        @store&.delete(key)
      end
    end
  end
end

require 'legion/llm/cache'

RSpec.describe Legion::LLM::Cache do
  before(:each) do
    Legion::Cache.reset!
    # Ensure prompt_caching is enabled in settings
    Legion::Settings[:llm][:prompt_caching] = {
      enabled:        true,
      min_tokens:     1024,
      response_cache: { enabled: true, ttl_seconds: 300 }
    }
  end

  # ──────────────────────────────────────────────
  # .key
  # ──────────────────────────────────────────────
  describe '.key' do
    let(:base_args) do
      {
        model:       'claude-sonnet-4-6',
        provider:    'anthropic',
        messages:    [{ role: 'user', content: 'hello' }],
        temperature: nil
      }
    end

    it 'returns a 64-character hex string (SHA256)' do
      result = described_class.key(**base_args)
      expect(result).to match(/\A[0-9a-f]{64}\z/)
    end

    it 'is deterministic — same inputs produce the same key' do
      key1 = described_class.key(**base_args)
      key2 = described_class.key(**base_args)
      expect(key1).to eq(key2)
    end

    it 'changes when model differs' do
      key1 = described_class.key(**base_args)
      key2 = described_class.key(**base_args, model: 'gpt-4o')
      expect(key1).not_to eq(key2)
    end

    it 'changes when provider differs' do
      key1 = described_class.key(**base_args)
      key2 = described_class.key(**base_args, provider: 'openai')
      expect(key1).not_to eq(key2)
    end

    it 'changes when messages differ' do
      key1 = described_class.key(**base_args)
      key2 = described_class.key(**base_args, messages: [{ role: 'user', content: 'bye' }])
      expect(key1).not_to eq(key2)
    end

    it 'changes when temperature differs' do
      key1 = described_class.key(**base_args, temperature: nil)
      key2 = described_class.key(**base_args, temperature: 0.5)
      expect(key1).not_to eq(key2)
    end

    it 'changes when tools differ' do
      key1 = described_class.key(**base_args)
      key2 = described_class.key(**base_args, tools: ['search'])
      expect(key1).not_to eq(key2)
    end

    it 'changes when schema differs' do
      key1 = described_class.key(**base_args)
      key2 = described_class.key(**base_args, schema: { type: 'object' })
      expect(key1).not_to eq(key2)
    end
  end

  # ──────────────────────────────────────────────
  # .enabled?
  # ──────────────────────────────────────────────
  describe '.enabled?' do
    it 'returns true when response_cache.enabled is true and Legion::Cache is available' do
      expect(described_class.enabled?).to be true
    end

    it 'returns false when response_cache.enabled is false' do
      Legion::Settings[:llm][:prompt_caching] = { response_cache: { enabled: false } }
      expect(described_class.enabled?).to be false
    end
  end

  # ──────────────────────────────────────────────
  # .get
  # ──────────────────────────────────────────────
  describe '.get' do
    let(:cache_key) { 'test-cache-key-abc' }

    it 'returns nil on a cache miss' do
      expect(described_class.get(cache_key)).to be_nil
    end

    it 'returns the stored response on a cache hit' do
      stored = { content: 'Hello!', meta: { model: 'claude-sonnet-4-6' } }
      Legion::Cache.set(cache_key, JSON.dump(stored))
      result = described_class.get(cache_key)
      expect(result[:content]).to eq('Hello!')
    end

    it 'returns symbolized keys' do
      stored = { 'content' => 'Hi', 'meta' => {} }
      Legion::Cache.set(cache_key, JSON.dump(stored))
      result = described_class.get(cache_key)
      expect(result).to have_key(:content)
    end

    it 'returns nil when cache returns invalid JSON' do
      Legion::Cache.set(cache_key, 'not-json{{{')
      expect(described_class.get(cache_key)).to be_nil
    end
  end

  # ──────────────────────────────────────────────
  # .set
  # ──────────────────────────────────────────────
  describe '.set' do
    let(:cache_key) { 'test-set-key-xyz' }
    let(:response)  { { content: 'Stored response', meta: { model: 'gpt-4o' } } }

    it 'returns true on success' do
      expect(described_class.set(cache_key, response)).to be true
    end

    it 'stores the response so .get retrieves it' do
      described_class.set(cache_key, response, ttl: 300)
      result = described_class.get(cache_key)
      expect(result[:content]).to eq('Stored response')
    end

    it 'accepts a custom TTL' do
      expect(described_class.set(cache_key, response, ttl: 60)).to be true
    end
  end

  # ──────────────────────────────────────────────
  # guard when Legion::Cache is unavailable
  # ──────────────────────────────────────────────
  describe 'when Legion::Cache is unavailable' do
    before do
      # Hide Legion::Cache by making respond_to?(:get) return false
      allow(Legion::Cache).to receive(:respond_to?).with(:get).and_return(false)
    end

    it '.enabled? returns false' do
      expect(described_class.enabled?).to be false
    end

    it '.get returns nil without raising' do
      expect(described_class.get('any-key')).to be_nil
    end

    it '.set returns false without raising' do
      expect(described_class.set('any-key', { content: 'x' })).to be false
    end
  end

  # ──────────────────────────────────────────────
  # skip conditions via chat_direct
  # ──────────────────────────────────────────────
  describe 'skip conditions in Legion::LLM.chat_direct' do
    let(:mock_response) { double('RubyLLM::Chat') }

    before do
      allow(RubyLLM).to receive(:chat).and_return(mock_response)
    end

    it 'skips cache when cache: false is passed' do
      expect(described_class).not_to receive(:get)
      Legion::LLM.chat_direct(message: 'hello', cache: false)
    end

    it 'skips cache when temperature > 0' do
      expect(described_class).not_to receive(:get)
      Legion::LLM.chat_direct(message: 'hello', temperature: 0.7)
    end

    it 'skips cache when message is nil' do
      expect(described_class).not_to receive(:get)
      Legion::LLM.chat_direct(message: nil)
    end
  end

  # ──────────────────────────────────────────────
  # cache hit returns cached: true in metadata
  # ──────────────────────────────────────────────
  describe 'cache hit flow' do
    it 'returns cached: true in meta on a cache hit' do
      stored = { content: 'Cached answer', meta: { model: 'claude-sonnet-4-6' } }
      messages_arr = [{ role: 'user', content: 'hello' }]
      # Build the key exactly as chat_direct does (resolves defaults from settings)
      effective_model    = Legion::LLM.settings[:default_model]
      effective_provider = Legion::LLM.settings[:default_provider]
      cache_key = described_class.key(
        model:       effective_model,
        provider:    effective_provider,
        messages:    messages_arr,
        temperature: nil
      )
      described_class.set(cache_key, stored, ttl: 300)

      result = Legion::LLM.chat_direct(message: 'hello', temperature: nil)
      expect(result[:meta][:cached]).to be true
    end
  end

  # ──────────────────────────────────────────────
  # constants
  # ──────────────────────────────────────────────
  describe 'constants' do
    it 'defines DEFAULT_TTL as 300' do
      expect(described_class::DEFAULT_TTL).to eq(300)
    end
  end
end
