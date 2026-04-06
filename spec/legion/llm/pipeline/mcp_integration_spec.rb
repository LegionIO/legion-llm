# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'MCP Client end-to-end pipeline integration' do
  let(:filesystem_tools) do
    [
      { name: 'list_files', description: 'List files in directory',
        input_schema: { properties: { path: { type: 'string' } } },
        source: { type: :mcp, server: 'filesystem' } }
    ]
  end

  let(:tool_result) do
    { content: [{ type: 'text', text: '["app.rb", "spec/"]' }], error: false }
  end

  describe 'Step 9 — tool discovery feeds into pipeline enrichments' do
    it 'populates discovered_tools from MCP servers' do
      pool_mod = Module.new
      allow(pool_mod).to receive(:all_tools).and_return(filesystem_tools)
      stub_const('Legion::MCP::Client::Pool', pool_mod)

      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'list the files' }]
      )
      executor = Legion::LLM::Pipeline::Executor.new(request)

      allow(executor).to receive(:step_provider_call)
      allow(executor).to receive(:step_response_normalization)

      executor.send(:step_mcp_discovery)

      expect(executor.discovered_tools.size).to eq(1)
      expect(executor.discovered_tools.first[:name]).to eq('list_files')
      expect(executor.enrichments).to have_key('tool:discovery')
    end
  end

  describe 'Step 14 — tool dispatch routes MCP tools via connection' do
    it 'routes list_files tool call through MCP client pool' do
      conn = double('Connection')
      allow(conn).to receive(:call_tool).with(
        name: 'list_files', arguments: { path: '.' }
      ).and_return(tool_result)

      pool_mod = Module.new
      allow(pool_mod).to receive(:connection_for).with('filesystem').and_return(conn)
      stub_const('Legion::MCP::Client::Pool', pool_mod)

      result = Legion::LLM::Pipeline::ToolDispatcher.dispatch(
        tool_call: { name: 'list_files', arguments: { path: '.' } },
        source:    { type: :mcp, server: 'filesystem' }
      )

      expect(result[:status]).to eq(:success)
      expect(result[:result]).to include('app.rb')
      expect(result[:source][:type]).to eq(:mcp)
    end
  end

  describe 'override mechanism' do
    it 'replaces MCP tool with LEX runner when override is configured' do
      allow(Legion::Settings).to receive(:dig).with(:mcp, :overrides).and_return({
                                                                                   'list_files' => { lex: 'lex-filesystem', runner: 'Files', function: 'list' }
                                                                                 })

      runner = double('Files')
      allow(runner).to receive(:list).with(path: '.').and_return(['app.rb'])
      stub_const('Legion::Extensions::Filesystem::Runners::Files', runner)

      result = Legion::LLM::Pipeline::ToolDispatcher.dispatch(
        tool_call: { name: 'list_files', arguments: { path: '.' } },
        source:    { type: :mcp, server: 'filesystem' }
      )

      expect(result[:status]).to eq(:success)
      expect(result[:source][:type]).to eq(:extension)
      expect(result[:source][:overridden_from]).to eq({ type: :mcp, server: 'filesystem' })
    end
  end
end
