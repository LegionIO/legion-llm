# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::ToolDispatcher do
  describe '.dispatch' do
    it 'routes MCP tools to MCP client' do
      tool_call = { name: 'list_files', arguments: { path: '.' } }
      source = { type: :mcp, server: 'filesystem' }

      conn = double('Connection')
      allow(conn).to receive(:call_tool).and_return({
        content: [{ type: 'text', text: '["a.rb"]' }]
      })

      pool_mod = Module.new
      allow(pool_mod).to receive(:connection_for).with('filesystem').and_return(conn)
      stub_const('Legion::MCP::Client::Pool', pool_mod)

      result = described_class.dispatch(tool_call: tool_call, source: source)
      expect(result[:status]).to eq(:success)
      expect(result[:result]).to include('a.rb')
    end

    it 'routes extension tools to LEX runner' do
      tool_call = { name: 'close_pr', arguments: { pr_id: 123 } }
      source = { type: :extension, lex: 'lex-github', runner: 'PullRequest', function: 'close' }

      runner = double('PullRequest')
      allow(runner).to receive(:close).with(pr_id: 123).and_return({ closed: true })
      stub_const('Legion::Extensions::Github::Runners::PullRequest', runner)

      result = described_class.dispatch(tool_call: tool_call, source: source)
      expect(result[:status]).to eq(:success)
    end

    it 'checks settings override before MCP dispatch' do
      tool_call = { name: 'close_pr', arguments: { pr_id: 123 } }
      source = { type: :mcp, server: 'github' }

      allow(Legion::Settings).to receive(:dig).with(:mcp, :overrides).and_return({
        'close_pr' => { lex: 'lex-github', runner: 'PullRequest', function: 'close' }
      })

      runner = double('PullRequest')
      allow(runner).to receive(:close).and_return({ closed: true })
      stub_const('Legion::Extensions::Github::Runners::PullRequest', runner)

      result = described_class.dispatch(tool_call: tool_call, source: source)
      expect(result[:source][:type]).to eq(:extension)
      expect(result[:source][:overridden_from]).to eq(source)
    end
  end
end
