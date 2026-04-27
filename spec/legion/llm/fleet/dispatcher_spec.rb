# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Fleet::Dispatcher do
  describe '.fleet_available?' do
    it 'returns false when transport is not connected' do
      expect(described_class.fleet_available?).to eq(false)
    end
  end

  describe '.fleet_enabled?' do
    it 'returns true by default' do
      expect(described_class.fleet_enabled?).to eq(true)
    end

    it 'returns false when use_fleet is false' do
      Legion::Settings[:llm][:routing] = { use_fleet: false }
      expect(described_class.fleet_enabled?).to eq(false)
    end

    it 'returns false when string-keyed settings disable fleet' do
      Legion::Settings[:llm]['routing'] = { 'use_fleet' => false }
      expect(described_class.fleet_enabled?).to eq(false)
    end
  end

  describe '.dispatch' do
    it 'returns fleet_unavailable when fleet is not available' do
      result = described_class.dispatch(model: 'test', messages: [])
      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('fleet_unavailable')
    end

    it 'registers the reply future before publishing the request' do
      order = []
      future = instance_double(Concurrent::Promises::ResolvableFuture)
      allow(described_class).to receive(:fleet_available?).and_return(true)
      allow(future).to receive(:value!).and_return({ success: true })
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:register) do |correlation_id, expected: {}|
        order << :register
        expect(correlation_id).not_to be_nil
        expect(expected).to eq({})
        future
      end
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:deregister)
      allow(described_class).to receive(:publish_request) do
        order << :publish
        { accepted: true, status: :accepted }
      end

      described_class.dispatch(model: 'test', messages: [], timeout: 1)

      expect(order).to eq(%i[register publish])
    end

    it 'does not attach request metadata gates to legacy fleet replies' do
      future = instance_double(Concurrent::Promises::ResolvableFuture)
      allow(described_class).to receive(:fleet_available?).and_return(true)
      allow(future).to receive(:value!).and_return({ success: true })
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:deregister)
      allow(described_class).to receive(:publish_request).and_return({ accepted: true, status: :accepted })

      expect(Legion::LLM::Fleet::ReplyDispatcher).to receive(:register).with(String, expected: {}).and_return(future)

      described_class.dispatch(model: 'test', messages: [], timeout: 1)
    end

    it 'does not attach request metadata gates to request-object fleet replies' do
      future = instance_double(Concurrent::Promises::ResolvableFuture)
      allow(described_class).to receive(:fleet_available?).and_return(true)
      allow(future).to receive(:value!).and_return({ success: true })
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:deregister)
      allow(described_class).to receive(:publish_request).and_return({ accepted: true, status: :accepted })

      expect(Legion::LLM::Fleet::ReplyDispatcher).to receive(:register).with(String, expected: {}).and_return(future)

      described_class.dispatch(request: { model: 'test', request_type: 'chat', provider: 'ollama' })
    end

    it 'uses the effective wait timeout as the fleet message TTL' do
      published = nil
      future = instance_double(Concurrent::Promises::ResolvableFuture)
      allow(described_class).to receive(:fleet_available?).and_return(true)
      allow(future).to receive(:value!).and_return({ success: true })
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:register).and_return(future)
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:deregister)
      allow(described_class).to receive(:publish_request) do |**opts|
        published = opts
        { accepted: true, status: :accepted }
      end

      described_class.dispatch(model: 'test', messages: [], timeout: 7)

      expect(published[:ttl]).to eq(7)
    end

    it 'builds context-aware lanes from string-keyed request limits' do
      published = nil
      future = instance_double(Concurrent::Promises::ResolvableFuture)
      request = {
        'provider'     => 'ollama',
        'request_type' => 'chat',
        'model'        => 'qwen3.6:27b',
        'limits'       => { 'context_window' => 65_536 },
        'ttl'          => 9
      }
      allow(described_class).to receive(:fleet_available?).and_return(true)
      allow(future).to receive(:value!).and_return({ success: true })
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:register).and_return(future)
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:deregister)
      allow(described_class).to receive(:publish_request) do |**opts|
        published = opts
        { accepted: true, status: :accepted }
      end

      described_class.dispatch(request: request)

      expect(published[:routing_key]).to eq('llm.fleet.inference.qwen3-6-27b.ctx65536')
      expect(published[:ttl]).to eq(9)
    end

    it 'returns a structured error when fleet publish is unroutable' do
      allow(described_class).to receive(:fleet_available?).and_return(true)
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:register)
        .and_return(instance_double(Concurrent::Promises::ResolvableFuture))
      allow(Legion::LLM::Fleet::ReplyDispatcher).to receive(:deregister)
      allow(described_class).to receive(:publish_request)
        .and_return({ accepted: false, status: :unroutable })

      result = described_class.dispatch(model: 'test', messages: [], message_context: { request_id: 'req-1' })

      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('no_fleet_queue')
      expect(result[:publish_status]).to eq(:unroutable)
      expect(result[:message_context]).to eq({ request_id: 'req-1' })
    end
  end

  describe '.resolve_timeout' do
    it 'returns default timeout when no override' do
      expect(described_class.resolve_timeout).to eq(30)
    end

    it 'returns override when provided' do
      expect(described_class.resolve_timeout(override: 60)).to eq(60)
    end

    it 'reads from settings' do
      Legion::Settings[:llm][:routing] = { tiers: { fleet: { timeout_seconds: 45 } } }
      expect(described_class.resolve_timeout).to eq(45)
    end

    it 'reads per-type timeouts' do
      expect(described_class.resolve_timeout(request_type: :embed)).to eq(10)
    end

    it 'reads per-type timeouts from settings' do
      Legion::Settings[:llm][:routing] = { tiers: { fleet: { timeouts: { chat: 60 } } } }
      expect(described_class.resolve_timeout(request_type: :chat)).to eq(60)
    end

    it 'reads per-type timeouts from string-keyed settings' do
      Legion::Settings[:llm]['routing'] = {
        'tiers' => {
          'fleet' => {
            'timeouts'        => { 'embed' => 12 },
            'timeout_seconds' => 45
          }
        }
      }

      expect(described_class.resolve_timeout(request_type: :embed)).to eq(12)
      expect(described_class.resolve_timeout(request_type: :chat)).to eq(45)
    end
  end

  describe '.build_routing_key' do
    it 'builds shared fleet lane keys by default' do
      key = described_class.build_routing_key(provider: 'ollama', request_type: 'chat', model: 'qwen3.5:27b')
      expect(key).to eq('llm.fleet.inference.qwen3-5-27b')
    end

    it 'can build legacy provider/model keys for compatibility' do
      key = described_class.build_routing_key(
        provider:      'ollama',
        request_type:  'chat',
        model:         'qwen3.5:27b',
        routing_style: :legacy_provider_model
      )
      expect(key).to eq('llm.request.ollama.chat.qwen3.5.27b')
    end

    it 'can build target shared lane keys with context windows' do
      key = described_class.build_routing_key(
        provider:       'ollama',
        request_type:   'chat',
        model:          'qwen3.6:27b',
        context_window: 32_768,
        routing_style:  :shared_lane
      )

      expect(key).to eq('llm.fleet.inference.qwen3-6-27b.ctx32768')
    end

    it 'reads legacy routing style from string-keyed settings' do
      Legion::Settings[:llm]['routing'] = {
        'tiers' => { 'fleet' => { 'routing_style' => 'legacy_provider_model' } }
      }

      key = described_class.build_routing_key(provider: 'ollama', request_type: 'chat', model: 'qwen3.5:27b')

      expect(key).to eq('llm.request.ollama.chat.qwen3.5.27b')
    end
  end

  describe '.sanitize_model' do
    it 'replaces colons with dots' do
      expect(described_class.sanitize_model('qwen3.5:27b')).to eq('qwen3.5.27b')
    end

    it 'preserves other characters' do
      expect(described_class.sanitize_model('llama3.2')).to eq('llama3.2')
    end
  end

  describe '.error_result' do
    it 'includes message_context' do
      result = described_class.error_result('test', message_context: { id: 1 })
      expect(result[:message_context]).to eq({ id: 1 })
    end
  end

  describe '.timeout_result' do
    it 'includes message_context' do
      result = described_class.timeout_result('corr_1', 30, message_context: { id: 1 })
      expect(result[:message_context]).to eq({ id: 1 })
    end
  end
end

RSpec.describe Legion::LLM::Fleet::ReplyDispatcher do
  before do
    described_class.reset!
    allow(described_class).to receive(:ensure_consumer)
  end

  it 'preserves handler-side failure payloads without forcing success' do
    future = described_class.register('corr-123')

    described_class.handle_delivery(
      { correlation_id: 'corr-123', success: false, error: 'invalid_token' }
    )

    expect(future.value!).to eq(
      correlation_id: 'corr-123',
      success:        false,
      error:          'invalid_token'
    )
  end

  it 'handles llm.fleet.error type by normalizing error payload' do
    future = described_class.register('corr-456')

    described_class.handle_delivery(
      { error: { code: 'model_not_loaded', message: 'not available' }, correlation_id: 'corr-456',
        message_context: { conv: 'c1' } },
      { correlation_id: 'corr-456', type: 'llm.fleet.error' }
    )

    result = future.value!
    expect(result[:success]).to eq(false)
    expect(result[:error]).to eq('model_not_loaded')
    expect(result[:correlation_id]).to eq('corr-456')
    expect(result[:message_context]).to eq({ conv: 'c1' })
  end

  it 'handles string-keyed fleet errors from JSON payloads' do
    future = described_class.register('corr-json')

    described_class.handle_delivery(
      {
        'error'           => { 'code' => 'model_not_loaded', 'message' => 'not available' },
        'correlation_id'  => 'corr-json',
        'message_context' => { 'request_id' => 'req-json' }
      },
      { 'correlation_id' => 'corr-json', 'type' => 'llm.fleet.error' }
    )

    result = future.value!
    expect(result[:success]).to eq(false)
    expect(result[:error]).to eq('model_not_loaded')
    expect(result[:correlation_id]).to eq('corr-json')
    expect(result[:message_context]).to eq({ 'request_id' => 'req-json' })
  end

  it 'uses string-keyed properties for correlation matching' do
    future = described_class.register('corr-props')

    described_class.handle_delivery({ success: true }, { 'correlation_id' => 'corr-props' })

    expect(future.value!).to eq(success: true)
  end

  it 'handles llm.fleet.response type as passthrough' do
    future = described_class.register('corr-789')

    described_class.handle_delivery(
      { success: true, content: 'hello' },
      { correlation_id: 'corr-789', type: 'llm.fleet.response' }
    )

    result = future.value!
    expect(result[:success]).to eq(true)
  end

  it 'does not fulfill a response that conflicts with expected metadata' do
    future = described_class.register('corr-expected', expected: { model: 'qwen3.6' })

    described_class.handle_delivery(
      { correlation_id: 'corr-expected', model: 'llama3.2', success: true }
    )

    expect(described_class.pending_count).to eq(1)

    described_class.handle_delivery(
      { correlation_id: 'corr-expected', model: 'qwen3.6', success: true }
    )

    expect(future.value![:success]).to eq(true)
    expect(described_class.pending_count).to eq(0)
  end

  it 'does not fulfill a response missing required expected metadata' do
    future = described_class.register('corr-missing', expected: { model: 'qwen3.6' })

    described_class.handle_delivery(
      { correlation_id: 'corr-missing', success: true }
    )

    expect(described_class.pending_count).to eq(1)

    described_class.handle_delivery(
      { correlation_id: 'corr-missing', model: 'qwen3.6', success: true }
    )

    expect(future.value![:success]).to eq(true)
    expect(described_class.pending_count).to eq(0)
  end

  describe '.fulfill_return' do
    it 'fulfills with no_fleet_queue error' do
      future = described_class.register('corr-ret')
      described_class.fulfill_return('corr-ret')
      result = future.value!
      expect(result[:error]).to eq('no_fleet_queue')
      expect(result[:correlation_id]).to eq('corr-ret')
    end
  end

  describe '.fulfill_nack' do
    it 'fulfills with fleet_backpressure error' do
      future = described_class.register('corr-nack')
      described_class.fulfill_nack('corr-nack')
      result = future.value!
      expect(result[:error]).to eq('fleet_backpressure')
      expect(result[:correlation_id]).to eq('corr-nack')
    end
  end
end
