# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/transport/messages/fleet_error'

RSpec.describe Legion::LLM::Transport::Messages::FleetError do
  let(:base_opts) do
    {
      reply_to:             'llm.fleet.reply.abc123',
      fleet_correlation_id: 'req_abc',
      provider:             'ollama',
      model:                'qwen3.5:27b',
      request_type:         'chat',
      message_context:      { conversation_id: 'conv_1' },
      error:                { code: 'model_not_loaded', message: 'not available', retriable: false, category: 'worker' }
    }
  end

  def build(**)
    described_class.new(**base_opts, **)
  end

  describe '#type' do
    it 'returns llm.fleet.error' do
      expect(build.type).to eq('llm.fleet.error')
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

  describe '#encrypt?' do
    it 'returns false' do
      expect(build.encrypt?).to eq(false)
    end
  end

  describe '#message_id' do
    it 'has err prefix' do
      expect(build.message_id).to match(/\Aerr_/)
    end
  end

  describe '#headers' do
    it 'adds x-legion-fleet-error when error code present' do
      expect(build.headers['x-legion-fleet-error']).to eq('model_not_loaded')
    end

    it 'skips error header when code is nil' do
      msg = build(error: { message: 'oops' })
      expect(msg.headers).not_to have_key('x-legion-fleet-error')
    end
  end

  describe '#app_id' do
    it 'is overridable to lex-ollama' do
      expect(build(app_id: 'lex-ollama').app_id).to eq('lex-ollama')
    end
  end

  describe 'ERROR_CODES' do
    it 'contains all expected codes' do
      expect(described_class::ERROR_CODES).to include('model_not_loaded', 'fleet_timeout', 'no_fleet_queue')
    end
  end
end
