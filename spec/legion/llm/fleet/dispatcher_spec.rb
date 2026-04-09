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
  end

  describe '.dispatch' do
    it 'returns fleet_unavailable when fleet is not available' do
      result = described_class.dispatch(model: 'test', messages: [])
      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('fleet_unavailable')
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
      Legion::Settings[:llm][:routing] = { fleet: { timeout_seconds: 45 } }
      expect(described_class.resolve_timeout).to eq(45)
    end

    it 'reads per-type timeouts' do
      expect(described_class.resolve_timeout(request_type: :embed)).to eq(10)
    end

    it 'reads per-type timeouts from settings' do
      Legion::Settings[:llm][:routing] = { fleet: { timeouts: { chat: 60 } } }
      expect(described_class.resolve_timeout(request_type: :chat)).to eq(60)
    end
  end

  describe '.build_routing_key' do
    it 'builds correct routing key' do
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
      { error: { code: 'model_not_loaded', message: 'not available' }, message_context: { conv: 'c1' } },
      { correlation_id: 'corr-456', type: 'llm.fleet.error' }
    )

    result = future.value!
    expect(result[:success]).to eq(false)
    expect(result[:error]).to eq('model_not_loaded')
    expect(result[:message_context]).to eq({ conv: 'c1' })
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

  describe '.fulfill_return' do
    it 'fulfills with no_fleet_queue error' do
      future = described_class.register('corr-ret')
      described_class.fulfill_return('corr-ret')
      result = future.value!
      expect(result[:error]).to eq('no_fleet_queue')
    end
  end

  describe '.fulfill_nack' do
    it 'fulfills with fleet_backpressure error' do
      future = described_class.register('corr-nack')
      described_class.fulfill_nack('corr-nack')
      result = future.value!
      expect(result[:error]).to eq('fleet_backpressure')
    end
  end
end
