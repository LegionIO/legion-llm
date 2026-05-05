# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::ToolDispatcher do
  describe 'shadow mode execution (removed)' do
    it 'no longer runs shadow executions via Catalog::Registry' do
      # Shadow mode was removed along with Catalog::Registry dependency.
      # The dispatcher now routes directly to MCP without shadow execution.
      tool_call = { name: 'list_files', arguments: {} }
      source = { type: :mcp, server: 'filesystem' }

      conn = double('Connection')
      allow(conn).to receive(:call_tool).and_return({
                                                      content: [{ type: 'text', text: '[]' }]
                                                    })
      pool_mod = Module.new
      allow(pool_mod).to receive(:connection_for).with('filesystem').and_return(conn)
      stub_const('Legion::MCP::Client::Pool', pool_mod)

      result = described_class.dispatch(tool_call: tool_call, source: source)
      expect(result[:source][:type]).to eq(:mcp)
      expect(result[:status]).to eq(:success)
    end
  end
end
