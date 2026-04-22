# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'

# Stub Legion::Cache with an in-memory hash if not already loaded
unless defined?(Legion::Cache)
  module Legion
    module Cache
      class << self
        def reset!
          @store = {}
        end

        def get(key)
          entry = @store&.dig(key)
          return nil if entry.nil?

          # Respect TTL
          return nil if entry[:expires_at] && ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > entry[:expires_at]

          entry[:value]
        end

        def set(key, value, ttl = 180)
          @store ||= {}
          expires_at = ttl.positive? ? ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + ttl : nil
          @store[key] = { value: value, expires_at: expires_at }
          true
        end

        def delete(key)
          @store&.delete(key)
        end
      end
    end
  end
end

require 'legion/llm/cache/response'

RSpec.describe Legion::LLM::Cache::Response do
  let(:request_id) { 'test-req-001' }
  let(:spool_dir) { Dir.mktmpdir('llm-response-cache') }

  before(:each) do
    Legion::Cache.reset!
    Legion::Settings[:llm][:prompt_caching][:response_cache][:spool_dir] = spool_dir
  end

  after(:each) do
    described_class.cleanup(request_id)
    FileUtils.remove_entry(spool_dir) if File.directory?(spool_dir)
  end

  # ──────────────────────────────────────────────
  # init_request
  # ──────────────────────────────────────────────
  describe '.init_request' do
    it 'sets status to :pending' do
      described_class.init_request(request_id, ttl: 300)
      expect(described_class.status(request_id)).to eq(:pending)
    end

    it 'uses the provided TTL' do
      described_class.init_request(request_id, ttl: 60)
      expect(described_class.status(request_id)).to eq(:pending)
    end
  end

  # ──────────────────────────────────────────────
  # complete
  # ──────────────────────────────────────────────
  describe '.complete' do
    it 'sets status to :done' do
      described_class.complete(request_id, response: 'Hello!', meta: { model: 'gpt-4o' }, ttl: 300)
      expect(described_class.status(request_id)).to eq(:done)
    end

    it 'stores the response string' do
      described_class.complete(request_id, response: 'Hello world', meta: {}, ttl: 300)
      expect(described_class.response(request_id)).to eq('Hello world')
    end

    it 'stores meta as JSON with symbolized keys on read' do
      described_class.complete(request_id, response: 'ok', meta: { model: 'gpt-4o', tokens: 42 }, ttl: 300)
      result = described_class.meta(request_id)
      expect(result[:model]).to eq('gpt-4o')
      expect(result[:tokens]).to eq(42)
    end
  end

  # ──────────────────────────────────────────────
  # fail_request
  # ──────────────────────────────────────────────
  describe '.fail_request' do
    it 'sets status to :error' do
      described_class.fail_request(request_id, code: 503, message: 'timeout', ttl: 300)
      expect(described_class.status(request_id)).to eq(:error)
    end

    it 'stores error code and message with symbolized keys' do
      described_class.fail_request(request_id, code: 429, message: 'rate limited', ttl: 300)
      result = described_class.error(request_id)
      expect(result[:code]).to eq(429)
      expect(result[:message]).to eq('rate limited')
    end
  end

  # ──────────────────────────────────────────────
  # status
  # ──────────────────────────────────────────────
  describe '.status' do
    it 'returns nil when request does not exist' do
      expect(described_class.status('nonexistent-id')).to be_nil
    end

    it 'returns :pending after init' do
      described_class.init_request(request_id, ttl: 300)
      expect(described_class.status(request_id)).to eq(:pending)
    end

    it 'returns :done after complete' do
      described_class.complete(request_id, response: 'hi', meta: {}, ttl: 300)
      expect(described_class.status(request_id)).to eq(:done)
    end

    it 'returns :error after fail_request' do
      described_class.fail_request(request_id, code: 500, message: 'boom', ttl: 300)
      expect(described_class.status(request_id)).to eq(:error)
    end
  end

  # ──────────────────────────────────────────────
  # response
  # ──────────────────────────────────────────────
  describe '.response' do
    it 'returns nil when no response is stored' do
      expect(described_class.response(request_id)).to be_nil
    end

    it 'returns the stored response string' do
      described_class.complete(request_id, response: 'Result text', meta: {}, ttl: 300)
      expect(described_class.response(request_id)).to eq('Result text')
    end
  end

  # ──────────────────────────────────────────────
  # meta
  # ──────────────────────────────────────────────
  describe '.meta' do
    it 'returns nil when no meta is stored' do
      expect(described_class.meta(request_id)).to be_nil
    end

    it 'returns empty hash for empty meta' do
      described_class.complete(request_id, response: 'ok', meta: {}, ttl: 300)
      expect(described_class.meta(request_id)).to eq({})
    end

    it 'returns symbolized keys' do
      described_class.complete(request_id, response: 'ok', meta: { provider: 'openai' }, ttl: 300)
      result = described_class.meta(request_id)
      expect(result).to have_key(:provider)
    end
  end

  # ──────────────────────────────────────────────
  # error
  # ──────────────────────────────────────────────
  describe '.error' do
    it 'returns nil when no error is stored' do
      expect(described_class.error(request_id)).to be_nil
    end

    it 'returns hash with symbolized keys' do
      described_class.fail_request(request_id, code: 503, message: 'unavailable', ttl: 300)
      result = described_class.error(request_id)
      expect(result).to have_key(:code)
      expect(result).to have_key(:message)
    end
  end

  # ──────────────────────────────────────────────
  # poll
  # ──────────────────────────────────────────────
  describe '.poll' do
    context 'when request completes immediately' do
      it 'returns status :done with response and meta' do
        described_class.complete(request_id, response: 'answer', meta: { model: 'claude' }, ttl: 300)
        result = described_class.poll(request_id, timeout: 5, interval: 0.01)
        expect(result[:status]).to eq(:done)
        expect(result[:response]).to eq('answer')
        expect(result[:meta][:model]).to eq('claude')
      end
    end

    context 'when request fails immediately' do
      it 'returns status :error with error hash' do
        described_class.fail_request(request_id, code: 500, message: 'crash', ttl: 300)
        result = described_class.poll(request_id, timeout: 5, interval: 0.01)
        expect(result[:status]).to eq(:error)
        expect(result[:error][:code]).to eq(500)
        expect(result[:error][:message]).to eq('crash')
      end
    end

    context 'when timeout elapses before completion' do
      it 'returns status :timeout' do
        described_class.init_request(request_id, ttl: 300)
        result = described_class.poll(request_id, timeout: 0.05, interval: 0.01)
        expect(result[:status]).to eq(:timeout)
      end
    end

    context 'when request completes during polling' do
      it 'returns :done once status transitions' do
        described_class.init_request(request_id, ttl: 300)

        Thread.new do
          sleep 0.03
          described_class.complete(request_id, response: 'late answer', meta: {}, ttl: 300)
        end

        result = described_class.poll(request_id, timeout: 1, interval: 0.01)
        expect(result[:status]).to eq(:done)
        expect(result[:response]).to eq('late answer')
      end
    end
  end

  # ──────────────────────────────────────────────
  # cleanup
  # ──────────────────────────────────────────────
  describe '.cleanup' do
    it 'removes all cache keys for a request' do
      described_class.complete(request_id, response: 'to delete', meta: { x: 1 }, ttl: 300)
      described_class.cleanup(request_id)
      expect(described_class.status(request_id)).to be_nil
      expect(described_class.response(request_id)).to be_nil
      expect(described_class.meta(request_id)).to be_nil
    end

    it 'is safe to call on a nonexistent request' do
      expect { described_class.cleanup('no-such-id') }.not_to raise_error
    end
  end

  # ──────────────────────────────────────────────
  # spool overflow
  # ──────────────────────────────────────────────
  describe 'spool overflow' do
    # Build a response larger than 8MB
    let(:large_response) { 'x' * ((8 * 1024 * 1024) + 1) }

    it 'writes large responses to spool file' do
      described_class.complete(request_id, response: large_response, meta: {}, ttl: 300)
      spool_path = File.join(spool_dir, "#{request_id}.txt")
      expect(File.exist?(spool_path)).to be true
    end

    it 'stores spool pointer in cache' do
      described_class.complete(request_id, response: large_response, meta: {}, ttl: 300)
      raw = Legion::Cache.get("llm:#{request_id}:response")
      expect(raw).to start_with('spool:')
    end

    it 'reads back the full large response transparently' do
      described_class.complete(request_id, response: large_response, meta: {}, ttl: 300)
      result = described_class.response(request_id)
      expect(result).to eq(large_response)
    end

    it 'removes spool file on cleanup' do
      described_class.complete(request_id, response: large_response, meta: {}, ttl: 300)
      described_class.cleanup(request_id)
      spool_path = File.join(spool_dir, "#{request_id}.txt")
      expect(File.exist?(spool_path)).to be false
    end
  end

  # ──────────────────────────────────────────────
  # constants
  # ──────────────────────────────────────────────
  describe 'defaults via settings' do
    it 'default ttl is 300 seconds' do
      expect(Legion::LLM::Settings.prompt_caching_defaults.dig(:response_cache, :ttl_seconds)).to eq(300)
    end

    it 'spool threshold default is 8MB' do
      expect(Legion::LLM::Settings.prompt_caching_defaults.dig(:response_cache, :spool_threshold_bytes)).to eq(8 * 1024 * 1024)
    end
  end
end
