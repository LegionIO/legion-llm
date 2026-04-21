# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/transport/exchanges/fleet'
require 'legion/llm/transport/messages/fleet_request'

RSpec.describe Legion::LLM::Transport::Messages::FleetRequest do
  let(:base_opts) do
    {
      routing_key:          'llm.request.ollama.chat.llama3.2',
      reply_to:             'llm.fleet.reply.abc123',
      fleet_correlation_id: 'req_abc',
      provider:             'ollama',
      model:                'llama3.2',
      request_type:         'chat',
      message_context:      { conversation_id: 'conv_1', message_id: 'msg_1', request_id: 'req_1' },
      messages:             [{ role: 'user', content: 'hello' }]
    }
  end

  def build(**)
    described_class.new(**base_opts, **)
  end

  describe '#type' do
    it 'returns llm.fleet.request' do
      expect(build.type).to eq('llm.fleet.request')
    end
  end

  describe '#routing_key' do
    it 'reads from options' do
      expect(build.routing_key).to eq('llm.request.ollama.chat.llama3.2')
    end
  end

  describe '#reply_to' do
    it 'reads from options' do
      expect(build.reply_to).to eq('llm.fleet.reply.abc123')
    end
  end

  describe '#priority' do
    it 'maps :critical to 9' do
      expect(build(priority: :critical).priority).to eq(9)
    end

    it 'maps :high to 7' do
      expect(build(priority: :high).priority).to eq(7)
    end

    it 'maps :normal to 5' do
      expect(build(priority: :normal).priority).to eq(5)
    end

    it 'maps :low to 2' do
      expect(build(priority: :low).priority).to eq(2)
    end

    it 'passes integer through' do
      expect(build(priority: 3).priority).to eq(3)
    end

    it 'defaults to 5 for unknown symbol' do
      expect(build(priority: :unknown).priority).to eq(5)
    end
  end

  describe '#expiration' do
    it 'converts TTL seconds to ms string' do
      expect(build(ttl: 30).expiration).to eq('30000')
    end

    it 'returns nil when no TTL' do
      expect(build.expiration).to be_nil
    end
  end

  describe '#message_id' do
    it 'has req prefix' do
      expect(build.message_id).to match(/\Areq_/)
    end
  end

  describe '#message (body)' do
    it 'excludes envelope keys' do
      body = build.message
      expect(body).not_to have_key(:fleet_correlation_id)
      expect(body).not_to have_key(:provider)
      expect(body).not_to have_key(:model)
      expect(body).not_to have_key(:ttl)
    end

    it 'includes message_context in body' do
      body = build.message
      expect(body[:message_context]).to eq({ conversation_id: 'conv_1', message_id: 'msg_1', request_id: 'req_1' })
    end

    it 'includes request_type in body' do
      body = build.message
      expect(body[:request_type]).to eq('chat')
    end
  end
end
