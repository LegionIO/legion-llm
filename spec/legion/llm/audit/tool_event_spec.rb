# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/transport/exchanges/audit'
require 'legion/llm/transport/messages/tool_event'

RSpec.describe Legion::LLM::Transport::Messages::ToolEvent do
  let(:base_opts) do
    {
      tool_name:       'list_files',
      provider:        'ollama',
      model:           'qwen3.5:27b',
      request_type:    'chat',
      message_context: { conversation_id: 'conv_1' },
      tool_call:       {
        name:   'list_files',
        source: { type: 'mcp', server: 'filesystem' },
        status: 'success'
      },
      classification:  { level: 'internal', contains_phi: false }
    }
  end

  def build(**)
    described_class.new(**base_opts, **)
  end

  describe '#type' do
    it 'returns llm.audit.tool' do
      expect(build.type).to eq('llm.audit.tool')
    end
  end

  describe '#routing_key' do
    it 'builds from tool_name' do
      expect(build.routing_key).to eq('audit.tool.list_files')
    end
  end

  describe '#encrypt?' do
    it 'returns false by default' do
      expect(build.encrypt?).to eq(false)
    end

    it 'returns true when encrypt_audit is enabled' do
      Legion::Settings[:llm][:compliance] = Legion::Settings[:llm][:compliance].merge(encrypt_audit: true)
      expect(build.encrypt?).to eq(true)
    end
  end

  describe '#message_id' do
    it 'has audit_tool prefix' do
      expect(build.message_id).to match(/\Aaudit_tool_/)
    end
  end

  describe '#headers' do
    let(:headers) { build.headers }

    it 'sets tool name' do
      expect(headers['x-legion-tool-name']).to eq('list_files')
    end

    it 'sets tool source type' do
      expect(headers['x-legion-tool-source-type']).to eq('mcp')
    end

    it 'sets tool source server' do
      expect(headers['x-legion-tool-source-server']).to eq('filesystem')
    end

    it 'sets tool status' do
      expect(headers['x-legion-tool-status']).to eq('success')
    end

    it 'sets classification' do
      expect(headers['x-legion-classification']).to eq('internal')
    end

    it 'sets phi header' do
      expect(headers['x-legion-contains-phi']).to eq('false')
    end

    it 'handles missing source gracefully' do
      msg = build(tool_call: { name: 'foo' })
      expect(msg.headers['x-legion-tool-name']).to eq('foo')
      expect(msg.headers).not_to have_key('x-legion-tool-source-type')
    end
  end
end
