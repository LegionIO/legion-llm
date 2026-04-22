# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/transport/exchanges/audit'
require 'legion/llm/transport/messages/prompt_event'

RSpec.describe Legion::LLM::Transport::Messages::PromptEvent do
  let(:base_opts) do
    {
      request_type:    'chat',
      provider:        'ollama',
      model:           'qwen3.5:27b',
      tier:            'fleet',
      message_context: { conversation_id: 'conv_1' },
      classification:  { level: 'internal', contains_phi: true, jurisdictions: %w[us eu], retention: 'permanent' },
      caller:          { requested_by: { identity: 'user:matt', type: 'user' } }
    }
  end

  def build(**)
    described_class.new(**base_opts, **)
  end

  describe '#type' do
    it 'returns llm.audit.prompt' do
      expect(build.type).to eq('llm.audit.prompt')
    end
  end

  describe '#routing_key' do
    it 'builds from request_type' do
      expect(build.routing_key).to eq('audit.prompt.chat')
    end
  end

  describe '#encrypt?' do
    it 'returns true always' do
      expect(build.encrypt?).to eq(true)
    end
  end

  describe '#message_id' do
    it 'has audit_prompt prefix' do
      expect(build.message_id).to match(/\Aaudit_prompt_/)
    end
  end

  describe '#headers' do
    let(:headers) { build.headers }

    it 'sets classification header' do
      expect(headers['x-legion-classification']).to eq('internal')
    end

    it 'sets phi header' do
      expect(headers['x-legion-contains-phi']).to eq('true')
    end

    it 'sets jurisdiction header as comma-joined' do
      expect(headers['x-legion-jurisdictions']).to eq('us,eu')
    end

    it 'sets caller identity' do
      expect(headers['x-legion-caller-identity']).to eq('user:matt')
    end

    it 'sets caller type' do
      expect(headers['x-legion-caller-type']).to eq('user')
    end

    it 'sets retention' do
      expect(headers['x-legion-retention']).to eq('permanent')
    end

    it 'sets tier' do
      expect(headers['x-legion-llm-tier']).to eq('fleet')
    end
  end
end
