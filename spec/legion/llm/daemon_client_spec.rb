# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/daemon_client'

RSpec.describe Legion::LLM::DaemonClient do
  before(:each) do
    described_class.reset!
  end

  # ──────────────────────────────────────────────
  # constants
  # ──────────────────────────────────────────────
  describe 'constants' do
    it 'defines HEALTH_CACHE_TTL as 30' do
      expect(described_class::HEALTH_CACHE_TTL).to eq(30)
    end

    it 'defines DEFAULT_TIMEOUT as 60' do
      expect(described_class::DEFAULT_TIMEOUT).to eq(60)
    end
  end

  # ──────────────────────────────────────────────
  # reset!
  # ──────────────────────────────────────────────
  describe '.reset!' do
    it 'clears cached url' do
      allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: 'http://localhost:4000' } })
      described_class.daemon_url # populate cache
      described_class.reset!
      allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: 'http://other:9000' } })
      expect(described_class.daemon_url).to eq('http://other:9000')
    end

    it 'clears healthy state' do
      allow(described_class).to receive(:check_health).and_return(true)
      allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: 'http://localhost:4000' } })
      described_class.available? # populate health cache
      described_class.reset!
      # After reset, available? should re-call check_health
      expect(described_class).to receive(:check_health).and_return(false)
      described_class.available?
    end

    it 'returns self for chaining' do
      expect(described_class.reset!).to eq(described_class)
    end
  end

  # ──────────────────────────────────────────────
  # daemon_url
  # ──────────────────────────────────────────────
  describe '.daemon_url' do
    context 'when Legion::LLM.settings returns a daemon url' do
      before do
        allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: 'http://daemon:4000' } })
      end

      it 'returns the url from settings' do
        expect(described_class.daemon_url).to eq('http://daemon:4000')
      end

      it 'caches the url on subsequent calls' do
        expect(Legion::LLM).to receive(:settings).once.and_return({ daemon: { url: 'http://daemon:4000' } })
        described_class.daemon_url
        described_class.daemon_url
      end
    end

    context 'when Legion::LLM does not respond to settings' do
      before do
        allow(Legion::LLM).to receive(:respond_to?).with(:settings).and_return(false)
      end

      it 'returns nil' do
        expect(described_class.daemon_url).to be_nil
      end
    end

    context 'when daemon url is nil in settings' do
      before do
        allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: nil } })
      end

      it 'returns nil' do
        expect(described_class.daemon_url).to be_nil
      end
    end

    context 'when daemon key is missing from settings' do
      before do
        allow(Legion::LLM).to receive(:settings).and_return({})
      end

      it 'returns nil' do
        expect(described_class.daemon_url).to be_nil
      end
    end

    context 'when settings raises an exception' do
      before do
        allow(Legion::LLM).to receive(:settings).and_raise(StandardError, 'settings unavailable')
      end

      it 'returns nil' do
        expect(described_class.daemon_url).to be_nil
      end
    end
  end

  # ──────────────────────────────────────────────
  # available?
  # ──────────────────────────────────────────────
  describe '.available?' do
    context 'when daemon_url is nil' do
      before do
        allow(Legion::LLM).to receive(:settings).and_return({})
      end

      it 'returns false without calling check_health' do
        expect(described_class).not_to receive(:check_health)
        expect(described_class.available?).to be false
      end
    end

    context 'when daemon_url is present and health check passes' do
      before do
        allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: 'http://localhost:4000' } })
        allow(described_class).to receive(:check_health).and_return(true)
      end

      it 'returns true' do
        expect(described_class.available?).to be true
      end
    end

    context 'when daemon_url is present and health check fails' do
      before do
        allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: 'http://localhost:4000' } })
        allow(described_class).to receive(:check_health).and_return(false)
      end

      it 'returns false' do
        expect(described_class.available?).to be false
      end
    end

    context 'caching behavior' do
      before do
        allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: 'http://localhost:4000' } })
      end

      it 'caches healthy result for HEALTH_CACHE_TTL seconds' do
        allow(described_class).to receive(:check_health).once.and_return(true)

        described_class.available?
        described_class.available?
        # check_health should only be called once due to caching
      end

      it 'calls check_health again after TTL expires' do
        allow(described_class).to receive(:check_health).and_return(true)

        described_class.available?

        # Simulate TTL expiry by manipulating timestamp
        described_class.instance_variable_set(:@health_checked_at,
                                              Process.clock_gettime(Process::CLOCK_MONOTONIC) -
                                              described_class::HEALTH_CACHE_TTL - 1)

        expect(described_class).to receive(:check_health).and_return(true)
        described_class.available?
      end

      it 'rechecks immediately when unhealthy' do
        # First call: unhealthy
        allow(described_class).to receive(:check_health).and_return(false)
        described_class.available?

        # Second call: should recheck (no caching when unhealthy)
        expect(described_class).to receive(:check_health).and_return(true)
        described_class.available?
      end
    end
  end

  # ──────────────────────────────────────────────
  # mark_unhealthy
  # ──────────────────────────────────────────────
  describe '.mark_unhealthy' do
    it 'sets healthy to false' do
      described_class.mark_unhealthy
      expect(described_class.instance_variable_get(:@healthy)).to be false
    end

    it 'records the timestamp' do
      before_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      described_class.mark_unhealthy
      after_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ts = described_class.instance_variable_get(:@health_checked_at)
      expect(ts).to be >= before_time
      expect(ts).to be <= after_time
    end
  end

  # ──────────────────────────────────────────────
  # check_health
  # ──────────────────────────────────────────────
  describe '.check_health' do
    before do
      allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: 'http://localhost:4000' } })
    end

    context 'when daemon returns 200' do
      it 'returns true and marks healthy' do
        response = double('Response', code: '200', body: '{"status":"ok"}')
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_get).and_return(response)

        result = described_class.check_health
        expect(result).to be true
        expect(described_class.instance_variable_get(:@healthy)).to be true
      end
    end

    context 'when daemon returns non-200' do
      it 'returns false and marks unhealthy' do
        response = double('Response', code: '503', body: '')
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_get).and_return(response)

        result = described_class.check_health
        expect(result).to be false
        expect(described_class.instance_variable_get(:@healthy)).to be false
      end
    end

    context 'when network error occurs' do
      it 'returns false and marks unhealthy' do
        allow(described_class).to receive(:http_get).and_raise(Errno::ECONNREFUSED, 'connection refused')

        result = described_class.check_health
        expect(result).to be false
        expect(described_class.instance_variable_get(:@healthy)).to be false
      end
    end
  end

  # ──────────────────────────────────────────────
  # http_post
  # ──────────────────────────────────────────────
  describe '.http_post' do
    before do
      allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: 'http://localhost:4000' } })
    end

    it 'makes a POST request to the daemon URL with JSON body' do
      response = double('Response', code: '200', body: '{"data":{"content":"hello"}}')
      allow(response).to receive(:[]).and_return(nil)

      http = double('Net::HTTP')
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request).and_return(response)

      allow(Net::HTTP).to receive(:new).with('localhost', 4000).and_return(http)

      result = described_class.http_post('/api/llm/chat', { message: 'hello' })
      expect(result).to eq(response)
    end
  end

  # ──────────────────────────────────────────────
  # interpret_response
  # ──────────────────────────────────────────────
  describe '.interpret_response' do
    context '200 OK' do
      it 'returns status :immediate with parsed body data' do
        body = JSON.dump({ data: { content: 'hello', model: 'claude' } })
        response = double('Response', code: '200', body: body)
        allow(response).to receive(:[]).and_return(nil)

        result = described_class.interpret_response(response)
        expect(result[:status]).to eq(:immediate)
        expect(result[:body]).to be_a(Hash)
      end
    end

    context '201 Created' do
      it 'returns status :created with parsed body data' do
        body = JSON.dump({ data: { content: 'created' } })
        response = double('Response', code: '201', body: body)
        allow(response).to receive(:[]).and_return(nil)

        result = described_class.interpret_response(response)
        expect(result[:status]).to eq(:created)
        expect(result[:body]).to be_a(Hash)
      end
    end

    context '202 Accepted' do
      it 'returns status :accepted with request_id and poll_key' do
        body = JSON.dump({ data: { request_id: 'req-123', poll_key: 'poll-abc' } })
        response = double('Response', code: '202', body: body)
        allow(response).to receive(:[]).and_return(nil)

        result = described_class.interpret_response(response)
        expect(result[:status]).to eq(:accepted)
        expect(result[:request_id]).to eq('req-123')
        expect(result[:poll_key]).to eq('poll-abc')
      end
    end

    context '403 Forbidden' do
      it 'returns status :denied with parsed error' do
        body = JSON.dump({ error: { message: 'Access denied' } })
        response = double('Response', code: '403', body: body)
        allow(response).to receive(:[]).and_return(nil)

        result = described_class.interpret_response(response)
        expect(result[:status]).to eq(:denied)
        expect(result[:error]).to be_a(Hash)
      end
    end

    context '429 Too Many Requests' do
      it 'returns status :rate_limited with retry_after as integer' do
        body = JSON.dump({ error: { retry_after: 60 } })
        response = double('Response', code: '429', body: body)
        allow(response).to receive(:[]).with('Retry-After').and_return('60')

        result = described_class.interpret_response(response)
        expect(result[:status]).to eq(:rate_limited)
        expect(result[:retry_after]).to be_an(Integer)
      end

      it 'falls back to Retry-After header when body has no retry_after' do
        body = JSON.dump({})
        response = double('Response', code: '429', body: body)
        allow(response).to receive(:[]).with('Retry-After').and_return('30')

        result = described_class.interpret_response(response)
        expect(result[:status]).to eq(:rate_limited)
        expect(result[:retry_after]).to eq(30)
      end
    end

    context '503 Service Unavailable' do
      it 'returns status :unavailable' do
        response = double('Response', code: '503', body: '')
        allow(response).to receive(:[]).and_return(nil)

        result = described_class.interpret_response(response)
        expect(result[:status]).to eq(:unavailable)
      end
    end

    context 'other error codes' do
      it 'returns status :error with code and parsed body' do
        body = JSON.dump({ error: { message: 'Internal server error' } })
        response = double('Response', code: '500', body: body)
        allow(response).to receive(:[]).and_return(nil)

        result = described_class.interpret_response(response)
        expect(result[:status]).to eq(:error)
        expect(result[:code]).to eq(500)
      end
    end
  end

  # ──────────────────────────────────────────────
  # chat
  # ──────────────────────────────────────────────
  describe '.chat' do
    before do
      allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: 'http://localhost:4000' } })
      allow(described_class).to receive(:available?).and_return(true)
    end

    context 'when daemon returns 200' do
      it 'returns :immediate status' do
        body = JSON.dump({ data: { content: 'hello world' } })
        response = double('Response', code: '200', body: body)
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.chat(message: 'hello')
        expect(result[:status]).to eq(:immediate)
      end
    end

    context 'when daemon returns 201' do
      it 'returns :created status' do
        body = JSON.dump({ data: { content: 'created response' } })
        response = double('Response', code: '201', body: body)
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.chat(message: 'hello')
        expect(result[:status]).to eq(:created)
      end
    end

    context 'when daemon returns 202' do
      it 'returns :accepted status with request_id and poll_key' do
        body = JSON.dump({ data: { request_id: 'req-xyz', poll_key: 'pk-abc' } })
        response = double('Response', code: '202', body: body)
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.chat(message: 'hello')
        expect(result[:status]).to eq(:accepted)
        expect(result[:request_id]).to eq('req-xyz')
        expect(result[:poll_key]).to eq('pk-abc')
      end
    end

    context 'when daemon returns 403' do
      it 'returns :denied status' do
        body = JSON.dump({ error: { message: 'forbidden' } })
        response = double('Response', code: '403', body: body)
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.chat(message: 'hello')
        expect(result[:status]).to eq(:denied)
      end
    end

    context 'when daemon returns 429' do
      it 'returns :rate_limited status' do
        body = JSON.dump({ error: { retry_after: 45 } })
        response = double('Response', code: '429', body: body)
        allow(response).to receive(:[]).with('Retry-After').and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.chat(message: 'hello')
        expect(result[:status]).to eq(:rate_limited)
        expect(result[:retry_after]).to be_an(Integer)
      end
    end

    context 'when daemon returns 503' do
      it 'returns :unavailable status' do
        response = double('Response', code: '503', body: '')
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.chat(message: 'hello')
        expect(result[:status]).to eq(:unavailable)
      end
    end

    context 'when network error occurs' do
      it 'returns :unavailable status with error message' do
        allow(described_class).to receive(:http_post).and_raise(Errno::ECONNREFUSED, 'connection refused')

        result = described_class.chat(message: 'hello')
        expect(result[:status]).to eq(:unavailable)
        expect(result[:error]).to be_a(String)
      end

      it 'marks the daemon as unhealthy' do
        allow(described_class).to receive(:http_post).and_raise(Errno::ECONNREFUSED, 'connection refused')
        expect(described_class).to receive(:mark_unhealthy)

        described_class.chat(message: 'hello')
      end
    end

    context 'request_id handling' do
      it 'auto-generates request_id when not provided' do
        body = JSON.dump({ data: {} })
        response = double('Response', code: '200', body: body)
        allow(response).to receive(:[]).and_return(nil)

        expect(described_class).to receive(:http_post) do |_path, body_hash|
          expect(body_hash[:request_id]).to match(/\A[0-9a-f-]{36}\z/)
          response
        end

        described_class.chat(message: 'hello')
      end

      it 'uses provided request_id when given' do
        body = JSON.dump({ data: {} })
        response = double('Response', code: '200', body: body)
        allow(response).to receive(:[]).and_return(nil)

        expect(described_class).to receive(:http_post) do |_path, body_hash|
          expect(body_hash[:request_id]).to eq('my-custom-id')
          response
        end

        described_class.chat(message: 'hello', request_id: 'my-custom-id')
      end

      it 'passes tier_preference, model, and provider in the request body' do
        body = JSON.dump({ data: {} })
        response = double('Response', code: '200', body: body)
        allow(response).to receive(:[]).and_return(nil)

        expect(described_class).to receive(:http_post) do |_path, body_hash|
          expect(body_hash[:tier_preference]).to eq(:cloud)
          expect(body_hash[:model]).to eq('claude-sonnet-4-6')
          expect(body_hash[:provider]).to eq(:anthropic)
          response
        end

        described_class.chat(message: 'hello', tier_preference: :cloud,
                             model: 'claude-sonnet-4-6', provider: :anthropic)
      end
    end
  end

  # ──────────────────────────────────────────────
  # http_post timeout keyword
  # ──────────────────────────────────────────────
  describe '.http_post timeout override' do
    before do
      allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: 'http://localhost:4000' } })
    end

    it 'uses DEFAULT_TIMEOUT when no timeout argument is given' do
      http = double('Net::HTTP')
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:request).and_return(double('Response', code: '200', body: '{}'))
      expect(http).to receive(:read_timeout=).with(described_class::DEFAULT_TIMEOUT)
      allow(Net::HTTP).to receive(:new).and_return(http)

      described_class.http_post('/api/llm/chat', {})
    end

    it 'uses a custom timeout when provided' do
      http = double('Net::HTTP')
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:request).and_return(double('Response', code: '200', body: '{}'))
      expect(http).to receive(:read_timeout=).with(120)
      allow(Net::HTTP).to receive(:new).and_return(http)

      described_class.http_post('/api/llm/inference', {}, timeout: 120)
    end
  end

  # ──────────────────────────────────────────────
  # inference
  # ──────────────────────────────────────────────
  describe '.inference' do
    before do
      allow(Legion::LLM).to receive(:settings).and_return({ daemon: { url: 'http://localhost:4000' } })
    end

    context 'when daemon returns 200 with content' do
      it 'returns status :ok with structured data' do
        payload = { data: { content: 'The answer is 42', tool_calls: [], stop_reason: 'end_turn',
                            model: 'claude-sonnet-4-6', input_tokens: 10, output_tokens: 5 } }
        response = double('Response', code: '200', body: JSON.dump(payload))
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.inference(messages: [{ role: 'user', content: 'hello' }])
        expect(result[:status]).to eq(:ok)
        expect(result[:data][:content]).to eq('The answer is 42')
        expect(result[:data][:tool_calls]).to eq([])
        expect(result[:data][:stop_reason]).to eq('end_turn')
        expect(result[:data][:model]).to eq('claude-sonnet-4-6')
        expect(result[:data][:input_tokens]).to eq(10)
        expect(result[:data][:output_tokens]).to eq(5)
      end
    end

    context 'when daemon returns 200 with tool_calls' do
      it 'returns status :ok and preserves tool_calls array' do
        tool_call = { id: 'call_1', name: 'search', arguments: { query: 'ruby docs' } }
        payload = { data: { content: nil, tool_calls: [tool_call], stop_reason: 'tool_use',
                            model: 'claude-sonnet-4-6', input_tokens: 20, output_tokens: 8 } }
        response = double('Response', code: '200', body: JSON.dump(payload))
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.inference(messages: [{ role: 'user', content: 'search for ruby docs' }])
        expect(result[:status]).to eq(:ok)
        expect(result[:data][:tool_calls].length).to eq(1)
        expect(result[:data][:stop_reason]).to eq('tool_use')
      end
    end

    context 'when daemon returns 200 and tool_calls is absent from body' do
      it 'defaults tool_calls to an empty array' do
        payload = { data: { content: 'hello', stop_reason: 'end_turn', model: 'gpt-4o',
                            input_tokens: 5, output_tokens: 2 } }
        response = double('Response', code: '200', body: JSON.dump(payload))
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.inference(messages: [])
        expect(result[:data][:tool_calls]).to eq([])
      end
    end

    context 'request body construction' do
      it 'sends messages and tools to /api/llm/inference' do
        response = double('Response', code: '200',
                                      body: JSON.dump({ data: { content: 'ok', tool_calls: [], stop_reason: 'end_turn',
                                                    model: 'x', input_tokens: 1, output_tokens: 1 } }))
        allow(response).to receive(:[]).and_return(nil)
        messages = [{ role: 'user', content: 'hi' }]
        tools    = [{ name: 'calculator', description: 'does math' }]

        expect(described_class).to receive(:http_post) do |path, body_hash, **_kwargs|
          expect(path).to eq('/api/llm/inference')
          expect(body_hash[:messages]).to eq(messages)
          expect(body_hash[:tools]).to eq(tools)
          response
        end

        described_class.inference(messages: messages, tools: tools)
      end

      it 'omits model key when model is nil' do
        response = double('Response', code: '200',
                                      body: JSON.dump({ data: { content: 'ok', tool_calls: [], stop_reason: 'end_turn',
                                                    model: 'x', input_tokens: 1, output_tokens: 1 } }))
        allow(response).to receive(:[]).and_return(nil)

        expect(described_class).to receive(:http_post) do |_path, body_hash, **_kwargs|
          expect(body_hash).not_to have_key(:model)
          response
        end

        described_class.inference(messages: [])
      end

      it 'includes model and provider when provided' do
        response = double('Response', code: '200',
                                      body: JSON.dump({ data: { content: 'ok', tool_calls: [], stop_reason: 'end_turn',
                                                    model: 'x', input_tokens: 1, output_tokens: 1 } }))
        allow(response).to receive(:[]).and_return(nil)

        expect(described_class).to receive(:http_post) do |_path, body_hash, **_kwargs|
          expect(body_hash[:model]).to eq('claude-sonnet-4-6')
          expect(body_hash[:provider]).to eq(:anthropic)
          response
        end

        described_class.inference(messages: [], model: 'claude-sonnet-4-6', provider: :anthropic)
      end

      it 'passes the timeout override to http_post' do
        response = double('Response', code: '200',
                                      body: JSON.dump({ data: { content: 'ok', tool_calls: [], stop_reason: 'end_turn',
                                                    model: 'x', input_tokens: 1, output_tokens: 1 } }))
        allow(response).to receive(:[]).and_return(nil)

        expect(described_class).to receive(:http_post)
          .with('/api/llm/inference', anything, timeout: 120)
          .and_return(response)

        described_class.inference(messages: [])
      end

      it 'passes a custom timeout when provided' do
        response = double('Response', code: '200',
                                      body: JSON.dump({ data: { content: 'ok', tool_calls: [], stop_reason: 'end_turn',
                                                    model: 'x', input_tokens: 1, output_tokens: 1 } }))
        allow(response).to receive(:[]).and_return(nil)

        expect(described_class).to receive(:http_post)
          .with('/api/llm/inference', anything, timeout: 300)
          .and_return(response)

        described_class.inference(messages: [], timeout: 300)
      end
    end

    context 'error response codes' do
      it 'returns :denied for 403' do
        body = JSON.dump({ error: { message: 'Access denied' } })
        response = double('Response', code: '403', body: body)
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.inference(messages: [])
        expect(result[:status]).to eq(:denied)
        expect(result[:error]).to be_a(Hash)
      end

      it 'returns :rate_limited for 429 with retry_after' do
        body = JSON.dump({ error: { retry_after: 30 } })
        response = double('Response', code: '429', body: body)
        allow(response).to receive(:[]).with('Retry-After').and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.inference(messages: [])
        expect(result[:status]).to eq(:rate_limited)
        expect(result[:retry_after]).to eq(30)
      end

      it 'returns :unavailable for 503' do
        response = double('Response', code: '503', body: '')
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.inference(messages: [])
        expect(result[:status]).to eq(:unavailable)
      end

      it 'returns :error with code for 500' do
        body = JSON.dump({ error: { message: 'Internal error' } })
        response = double('Response', code: '500', body: body)
        allow(response).to receive(:[]).and_return(nil)
        allow(described_class).to receive(:http_post).and_return(response)

        result = described_class.inference(messages: [])
        expect(result[:status]).to eq(:error)
        expect(result[:code]).to eq(500)
      end
    end

    context 'when a network error occurs' do
      it 'returns :unavailable status with the error message' do
        allow(described_class).to receive(:http_post).and_raise(Errno::ECONNREFUSED, 'connection refused')

        result = described_class.inference(messages: [])
        expect(result[:status]).to eq(:unavailable)
        expect(result[:error]).to be_a(String)
      end

      it 'marks the daemon as unhealthy' do
        allow(described_class).to receive(:http_post).and_raise(Errno::ECONNREFUSED, 'connection refused')
        expect(described_class).to receive(:mark_unhealthy)

        described_class.inference(messages: [])
      end
    end
  end
end
