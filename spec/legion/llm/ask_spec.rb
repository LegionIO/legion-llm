# frozen_string_literal: true

require 'spec_helper'

# Stub Legion::Cache for ResponseCache if not already defined
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

require 'legion/llm/response_cache'
require 'legion/llm/daemon_client'

RSpec.describe 'Legion::LLM.ask' do
  # Build a mock response object with the interface of RubyLLM::Message
  def mock_response(content: 'hello world', input_tokens: 10, output_tokens: 20)
    resp = double('Response', content: content)
    allow(resp).to receive(:respond_to?).with(:input_tokens).and_return(true)
    allow(resp).to receive(:respond_to?).with(:output_tokens).and_return(true)
    allow(resp).to receive(:input_tokens).and_return(input_tokens)
    allow(resp).to receive(:output_tokens).and_return(output_tokens)
    resp
  end

  # Build a mock chat session returned by chat_direct
  def mock_session(model_name: 'claude-sonnet-4-6', response_content: 'hello world')
    resp = mock_response(content: response_content)
    session = double('ChatSession', model: model_name)
    allow(session).to receive(:ask).and_return(resp)
    session
  end

  before(:each) do
    Legion::LLM::DaemonClient.reset!
    Legion::Cache.reset! if defined?(Legion::Cache) && Legion::Cache.respond_to?(:reset!)
  end

  # ─────────────────────────────────────────────
  # error classes
  # ─────────────────────────────────────────────
  describe 'error classes' do
    it 'defines DaemonDeniedError as a StandardError subclass' do
      expect(Legion::LLM::DaemonDeniedError.ancestors).to include(StandardError)
    end

    it 'defines DaemonRateLimitedError as a StandardError subclass' do
      expect(Legion::LLM::DaemonRateLimitedError.ancestors).to include(StandardError)
    end
  end

  # ─────────────────────────────────────────────
  # daemon path — immediate (200)
  # ─────────────────────────────────────────────
  describe 'daemon path: :immediate' do
    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(true)
      allow(Legion::LLM::DaemonClient).to receive(:chat).and_return(
        { status: :immediate, body: { content: 'daemon response' } }
      )
    end

    it 'returns the body from the daemon' do
      result = Legion::LLM.ask(message: 'hello')
      expect(result).to eq({ content: 'daemon response' })
    end

    it 'does not call chat_direct' do
      expect(Legion::LLM).not_to receive(:chat_direct)
      Legion::LLM.ask(message: 'hello')
    end
  end

  # ─────────────────────────────────────────────
  # daemon path — created (201)
  # ─────────────────────────────────────────────
  describe 'daemon path: :created' do
    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(true)
      allow(Legion::LLM::DaemonClient).to receive(:chat).and_return(
        { status: :created, body: { content: 'created response' } }
      )
    end

    it 'returns the body from the daemon' do
      result = Legion::LLM.ask(message: 'hello')
      expect(result).to eq({ content: 'created response' })
    end
  end

  # ─────────────────────────────────────────────
  # daemon path — accepted (202) — polls cache
  # ─────────────────────────────────────────────
  describe 'daemon path: :accepted' do
    let(:request_id) { 'req-poll-001' }

    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(true)
      allow(Legion::LLM::DaemonClient).to receive(:chat).and_return(
        { status: :accepted, request_id: request_id, poll_key: 'pk-abc' }
      )
    end

    context 'when poll resolves to :done' do
      before do
        Legion::LLM::ResponseCache.complete(
          request_id,
          response: 'async result',
          meta:     { model: 'claude-sonnet-4-6', tier: :fleet },
          ttl:      300
        )
      end

      after do
        Legion::LLM::ResponseCache.cleanup(request_id)
      end

      it 'returns the polled result' do
        result = Legion::LLM.ask(message: 'hello')
        expect(result[:status]).to eq(:done)
        expect(result[:response]).to eq('async result')
      end
    end

    context 'when poll times out' do
      it 'returns a timeout status hash' do
        # No completion written — poll will time out quickly
        result = Legion::LLM::ResponseCache.poll(request_id, timeout: 0.05, interval: 0.01)
        expect(result[:status]).to eq(:timeout)
      end
    end
  end

  # ─────────────────────────────────────────────
  # daemon path — denied (403) raises error
  # ─────────────────────────────────────────────
  describe 'daemon path: :denied' do
    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(true)
      allow(Legion::LLM::DaemonClient).to receive(:chat).and_return(
        { status: :denied, error: { message: 'Access denied by policy' } }
      )
    end

    it 'raises DaemonDeniedError' do
      expect { Legion::LLM.ask(message: 'hello') }.to raise_error(Legion::LLM::DaemonDeniedError)
    end

    it 'includes the daemon error message' do
      expect { Legion::LLM.ask(message: 'hello') }
        .to raise_error(Legion::LLM::DaemonDeniedError, 'Access denied by policy')
    end
  end

  describe 'daemon path: :denied with no message' do
    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(true)
      allow(Legion::LLM::DaemonClient).to receive(:chat).and_return(
        { status: :denied, error: {} }
      )
    end

    it 'raises DaemonDeniedError with fallback message' do
      expect { Legion::LLM.ask(message: 'hello') }
        .to raise_error(Legion::LLM::DaemonDeniedError, 'Access denied')
    end
  end

  # ─────────────────────────────────────────────
  # daemon path — rate_limited (429) raises error
  # ─────────────────────────────────────────────
  describe 'daemon path: :rate_limited' do
    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(true)
      allow(Legion::LLM::DaemonClient).to receive(:chat).and_return(
        { status: :rate_limited, retry_after: 45 }
      )
    end

    it 'raises DaemonRateLimitedError' do
      expect { Legion::LLM.ask(message: 'hello') }.to raise_error(Legion::LLM::DaemonRateLimitedError)
    end

    it 'includes retry_after in the error message' do
      expect { Legion::LLM.ask(message: 'hello') }
        .to raise_error(Legion::LLM::DaemonRateLimitedError, /45/)
    end
  end

  # ─────────────────────────────────────────────
  # daemon path — unavailable — falls through to direct
  # ─────────────────────────────────────────────
  describe 'daemon path: :unavailable falls through to direct' do
    let(:session) { mock_session }

    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(true)
      allow(Legion::LLM::DaemonClient).to receive(:chat).and_return({ status: :unavailable })
      allow(Legion::LLM).to receive(:chat_direct).and_return(session)
    end

    it 'falls through and calls chat_direct' do
      expect(Legion::LLM).to receive(:chat_direct)
      Legion::LLM.ask(message: 'hello')
    end

    it 'returns a done hash with direct response' do
      result = Legion::LLM.ask(message: 'hello')
      expect(result[:status]).to eq(:done)
      expect(result[:response]).to eq('hello world')
    end
  end

  # ─────────────────────────────────────────────
  # daemon path — :error — falls through to direct
  # ─────────────────────────────────────────────
  describe 'daemon path: :error falls through to direct' do
    let(:session) { mock_session }

    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(true)
      allow(Legion::LLM::DaemonClient).to receive(:chat).and_return({ status: :error, code: 500 })
      allow(Legion::LLM).to receive(:chat_direct).and_return(session)
    end

    it 'returns a done hash with direct response' do
      result = Legion::LLM.ask(message: 'hello')
      expect(result[:status]).to eq(:done)
    end
  end

  # ─────────────────────────────────────────────
  # daemon unavailable — goes straight to direct
  # ─────────────────────────────────────────────
  describe 'when DaemonClient is not available' do
    let(:session) { mock_session }

    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(false)
      allow(Legion::LLM).to receive(:chat_direct).and_return(session)
    end

    it 'skips daemon and calls chat_direct directly' do
      expect(Legion::LLM::DaemonClient).not_to receive(:chat)
      expect(Legion::LLM).to receive(:chat_direct)
      Legion::LLM.ask(message: 'hello')
    end

    it 'returns a done hash' do
      result = Legion::LLM.ask(message: 'hello')
      expect(result[:status]).to eq(:done)
    end
  end

  # ─────────────────────────────────────────────
  # direct path — return shape
  # ─────────────────────────────────────────────
  describe 'direct path return shape' do
    let(:session) { mock_session(model_name: 'claude-sonnet-4-6', response_content: 'direct answer') }

    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(false)
      allow(Legion::LLM).to receive(:chat_direct).and_return(session)
    end

    it 'returns { status: :done, response:, meta: }' do
      result = Legion::LLM.ask(message: 'hello')
      expect(result).to include(:status, :response, :meta)
    end

    it 'status is :done' do
      expect(Legion::LLM.ask(message: 'hello')[:status]).to eq(:done)
    end

    it 'response is the message content string' do
      expect(Legion::LLM.ask(message: 'hello')[:response]).to eq('direct answer')
    end

    it 'meta contains tier: :direct' do
      expect(Legion::LLM.ask(message: 'hello')[:meta][:tier]).to eq(:direct)
    end

    it 'meta contains the model name as a string' do
      expect(Legion::LLM.ask(message: 'hello')[:meta][:model]).to eq('claude-sonnet-4-6')
    end

    it 'meta contains tokens_in from response' do
      expect(Legion::LLM.ask(message: 'hello')[:meta][:tokens_in]).to eq(10)
    end

    it 'meta contains tokens_out from response' do
      expect(Legion::LLM.ask(message: 'hello')[:meta][:tokens_out]).to eq(20)
    end
  end

  # ─────────────────────────────────────────────
  # direct path — passes model/provider through
  # ─────────────────────────────────────────────
  describe 'direct path passes model and provider through' do
    let(:session) { mock_session }

    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(false)
    end

    it 'forwards model to chat_direct' do
      expect(Legion::LLM).to receive(:chat_direct).with(hash_including(model: 'gpt-4o')).and_return(session)
      Legion::LLM.ask(message: 'hello', model: 'gpt-4o')
    end

    it 'forwards provider to chat_direct' do
      expect(Legion::LLM).to receive(:chat_direct).with(hash_including(provider: :openai)).and_return(session)
      Legion::LLM.ask(message: 'hello', provider: :openai)
    end

    it 'forwards tier to chat_direct' do
      expect(Legion::LLM).to receive(:chat_direct).with(hash_including(tier: :cloud)).and_return(session)
      Legion::LLM.ask(message: 'hello', tier: :cloud)
    end

    it 'forwards intent to chat_direct' do
      expect(Legion::LLM).to receive(:chat_direct).with(hash_including(intent: { privacy: :strict })).and_return(session)
      Legion::LLM.ask(message: 'hello', intent: { privacy: :strict })
    end
  end

  # ─────────────────────────────────────────────
  # direct path — streaming block
  # ─────────────────────────────────────────────
  describe 'direct path supports streaming block' do
    let(:session) { mock_session }

    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(false)
      allow(Legion::LLM).to receive(:chat_direct).and_return(session)
    end

    it 'passes block to session.ask when a block is given' do
      stream_resp = double('StreamResponse', content: 'streamed')
      allow(stream_resp).to receive(:respond_to?).with(:input_tokens).and_return(false)
      allow(stream_resp).to receive(:respond_to?).with(:output_tokens).and_return(false)

      chunks = []
      expect(session).to receive(:ask) do |_msg, &blk|
        blk&.call('chunk1')
        stream_resp
      end

      result = Legion::LLM.ask(message: 'hello') { |chunk| chunks << chunk }
      expect(result[:status]).to eq(:done)
      expect(result[:response]).to eq('streamed')
      expect(chunks).to eq(['chunk1'])
    end
  end

  describe 'direct path with scheduling deferral' do
    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(false)
      Legion::LLM::Batch.reset!
      Legion::Settings[:llm][:batch] = { enabled: true, window_seconds: 300, max_batch_size: 100 }
      Legion::Settings[:llm][:scheduling] = {
        enabled:         true,
        peak_hours_utc:  '0-23',
        defer_intents:   %w[batch background],
        max_defer_hours: 8
      }
    end

    after do
      Legion::LLM::Batch.reset!
    end

    it 'returns a deferred result instead of raising on a deferred hash' do
      result = nil

      expect do
        result = Legion::LLM.ask(message: 'hello', intent: :batch)
      end.not_to raise_error

      expect(result[:deferred]).to be true
      expect(result[:batch_id]).to be_a(String)
      expect(Legion::LLM::Batch.queue_size).to eq(1)
    end
  end

  # ─────────────────────────────────────────────
  # daemon forwards model/provider/tier/context
  # ─────────────────────────────────────────────
  describe 'daemon call forwards options' do
    before do
      allow(Legion::LLM::DaemonClient).to receive(:available?).and_return(true)
    end

    it 'passes message, model, provider, context, and tier to DaemonClient.chat' do
      expect(Legion::LLM::DaemonClient).to receive(:chat).with(
        hash_including(
          message:         'test',
          model:           'llama3',
          provider:        :ollama,
          context:         { user: 'alice' },
          tier_preference: :local
        )
      ).and_return({ status: :immediate, body: 'ok' })

      Legion::LLM.ask(message: 'test', model: 'llama3', provider: :ollama,
                      context: { user: 'alice' }, tier: :local)
    end

    it 'maps nil tier to :auto for tier_preference' do
      expect(Legion::LLM::DaemonClient).to receive(:chat).with(
        hash_including(tier_preference: :auto)
      ).and_return({ status: :immediate, body: 'ok' })

      Legion::LLM.ask(message: 'hello')
    end
  end
end
