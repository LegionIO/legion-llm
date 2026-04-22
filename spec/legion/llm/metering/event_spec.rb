# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/transport/exchanges/metering'
require 'legion/llm/transport/messages/metering_event'

RSpec.describe Legion::LLM::Transport::Messages::MeteringEvent do
  let(:base_opts) do
    {
      request_type:    'chat',
      provider:        'ollama',
      model:           'qwen3.5:27b',
      tier:            'fleet',
      message_context: { conversation_id: 'conv_1' }
    }
  end

  def build(**)
    described_class.new(**base_opts, **)
  end

  describe '#type' do
    it 'returns llm.metering.event' do
      expect(build.type).to eq('llm.metering.event')
    end
  end

  describe '#routing_key' do
    it 'builds from request_type' do
      expect(build(request_type: 'chat').routing_key).to eq('metering.chat')
    end

    it 'handles nil request_type' do
      msg = described_class.new(provider: 'test')
      expect(msg.routing_key).to eq('metering.')
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
    it 'has meter prefix' do
      expect(build.message_id).to match(/\Ameter_/)
    end
  end

  describe '#headers' do
    it 'adds x-legion-llm-tier when tier is set' do
      expect(build(tier: 'fleet').headers['x-legion-llm-tier']).to eq('fleet')
    end
  end

  describe '#message (body)' do
    it 'includes request_type in body' do
      expect(build.message[:request_type]).to eq('chat')
    end
  end
end
