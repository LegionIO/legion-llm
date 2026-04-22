# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/transport/messages/fleet_response'

RSpec.describe Legion::LLM::Transport::Messages::FleetResponse do
  let(:base_opts) do
    {
      reply_to:             'llm.fleet.reply.abc123',
      fleet_correlation_id: 'req_abc',
      provider:             'ollama',
      model:                'qwen3.5:27b',
      request_type:         'chat',
      message_context:      { conversation_id: 'conv_1' }
    }
  end

  def build(**)
    described_class.new(**base_opts, **)
  end

  describe '#type' do
    it 'returns llm.fleet.response' do
      expect(build.type).to eq('llm.fleet.response')
    end
  end

  describe '#routing_key' do
    it 'reads reply_to' do
      expect(build.routing_key).to eq('llm.fleet.reply.abc123')
    end
  end

  describe '#priority' do
    it 'returns 0' do
      expect(build.priority).to eq(0)
    end
  end

  describe '#expiration' do
    it 'returns nil' do
      expect(build.expiration).to be_nil
    end
  end

  describe '#message_id' do
    it 'has resp prefix' do
      expect(build.message_id).to match(/\Aresp_/)
    end
  end

  describe '#app_id' do
    it 'defaults to legion-llm' do
      expect(build.app_id).to eq('legion-llm')
    end

    it 'is overridable to lex-ollama' do
      expect(build(app_id: 'lex-ollama').app_id).to eq('lex-ollama')
    end
  end

  describe '#headers' do
    it 'includes LLM and context headers' do
      headers = build.headers
      expect(headers['x-legion-llm-provider']).to eq('ollama')
      expect(headers['x-legion-llm-model']).to eq('qwen3.5:27b')
      expect(headers['x-legion-llm-conversation-id']).to eq('conv_1')
    end
  end
end
