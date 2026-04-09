# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/transport/message'

RSpec.describe Legion::LLM::Transport::Message do
  let(:base_opts) { { provider: 'ollama', model: 'qwen3.5:27b', request_type: 'chat' } }

  def build(**)
    described_class.new(**base_opts, **)
  end

  describe '#message_context' do
    it 'returns empty hash when not set' do
      msg = build
      expect(msg.message_context).to eq({})
    end

    it 'returns the hash when set' do
      ctx = { conversation_id: 'conv_abc', message_id: 'msg_001', request_id: 'req_xyz' }
      msg = build(message_context: ctx)
      expect(msg.message_context).to eq(ctx)
    end
  end

  describe '#message' do
    it 'strips LLM envelope keys from body' do
      msg = build(
        fleet_correlation_id: 'req_abc',
        ttl:                  30,
        system:               'You are helpful',
        messages:             [{ role: 'user', content: 'hi' }]
      )
      body = msg.message
      expect(body).not_to have_key(:fleet_correlation_id)
      expect(body).not_to have_key(:provider)
      expect(body).not_to have_key(:model)
      expect(body).not_to have_key(:ttl)
    end

    it 'keeps body fields' do
      msg = build(
        system:          'You are helpful',
        messages:        [{ role: 'user', content: 'hi' }],
        request_type:    'chat',
        message_context: { conversation_id: 'conv_1' }
      )
      body = msg.message
      expect(body[:system]).to eq('You are helpful')
      expect(body[:messages]).to eq([{ role: 'user', content: 'hi' }])
      expect(body[:request_type]).to eq('chat')
      expect(body[:message_context]).to eq({ conversation_id: 'conv_1' })
    end
  end

  describe '#message_id' do
    it 'auto-generates with msg prefix' do
      msg = build
      expect(msg.message_id).to match(/\Amsg_[0-9a-f-]{36}\z/)
    end

    it 'uses provided message_id' do
      msg = build(message_id: 'custom_123')
      expect(msg.message_id).to eq('custom_123')
    end
  end

  describe '#correlation_id' do
    it 'reads fleet_correlation_id when set' do
      msg = build(fleet_correlation_id: 'req_abc')
      expect(msg.correlation_id).to eq('req_abc')
    end

    it 'falls through to super when fleet_correlation_id absent' do
      msg = build(parent_id: 'parent_123')
      expect(msg.correlation_id).not_to eq('req_abc')
    end
  end

  describe '#app_id' do
    it 'defaults to legion-llm' do
      msg = build
      expect(msg.app_id).to eq('legion-llm')
    end

    it 'is overridable' do
      msg = build(app_id: 'lex-ollama')
      expect(msg.app_id).to eq('lex-ollama')
    end
  end

  describe '#headers' do
    it 'includes provider header' do
      msg = build(provider: 'ollama')
      expect(msg.headers['x-legion-llm-provider']).to eq('ollama')
    end

    it 'includes model header' do
      msg = build(model: 'qwen3.5:27b')
      expect(msg.headers['x-legion-llm-model']).to eq('qwen3.5:27b')
    end

    it 'always includes schema version' do
      msg = build
      expect(msg.headers['x-legion-llm-schema-version']).to eq('1.0.0')
    end

    it 'includes request type header' do
      msg = build(request_type: 'chat')
      expect(msg.headers['x-legion-llm-request-type']).to eq('chat')
    end

    it 'promotes conversation_id from message_context' do
      msg = build(message_context: { conversation_id: 'conv_abc' })
      expect(msg.headers['x-legion-llm-conversation-id']).to eq('conv_abc')
    end

    it 'promotes message_id from message_context' do
      msg = build(message_context: { message_id: 'msg_005' })
      expect(msg.headers['x-legion-llm-message-id']).to eq('msg_005')
    end

    it 'promotes request_id from message_context' do
      msg = build(message_context: { request_id: 'req_abc123' })
      expect(msg.headers['x-legion-llm-request-id']).to eq('req_abc123')
    end

    it 'skips nil context fields' do
      msg = build(message_context: {})
      expect(msg.headers).not_to have_key('x-legion-llm-conversation-id')
      expect(msg.headers).not_to have_key('x-legion-llm-message-id')
      expect(msg.headers).not_to have_key('x-legion-llm-request-id')
    end

    it 'omits provider header when not set' do
      msg = described_class.new(model: 'test')
      expect(msg.headers).not_to have_key('x-legion-llm-provider')
    end
  end

  describe '#tracing_headers' do
    it 'returns empty hash (stub)' do
      msg = build
      expect(msg.tracing_headers).to eq({})
    end
  end

  describe 'subclass prefix override' do
    let(:subclass) do
      Class.new(described_class) do
        private

        def message_id_prefix = 'req'
      end
    end

    it 'uses subclass prefix' do
      msg = subclass.new(**base_opts)
      expect(msg.message_id).to match(/\Areq_[0-9a-f-]{36}\z/)
    end
  end
end
