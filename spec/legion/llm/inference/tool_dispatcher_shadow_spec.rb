# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::ToolDispatcher do
  describe 'shadow mode execution' do
    before { Legion::LLM::Tools::Confidence.reset! }

    it 'executes both MCP and LEX in shadow mode when confidence is 0.5-0.8' do
      tool_call = { name: 'close_pr', arguments: { pr_id: 123 } }
      source = { type: :mcp, server: 'github' }

      allow(Legion::Settings).to receive(:dig).with(:mcp, :overrides).and_return(nil)

      # Catalog has a matching capability
      cap = double(extension: 'lex-github', runner: 'PullRequest', function: 'close')
      catalog_mod = Module.new
      allow(catalog_mod).to receive(:for_override).with('close_pr').and_return(cap)
      stub_const('Legion::Extensions::Catalog::Registry', catalog_mod)

      # Confidence in shadow range
      Legion::LLM::Tools::Confidence.record(
        tool: 'close_pr', lex: 'lex-github:PullRequest:close', confidence: 0.6
      )

      # MCP returns result
      conn = double('Connection')
      allow(conn).to receive(:call_tool).and_return({
                                                      content: [{ type: 'text', text: '{"closed":true}' }]
                                                    })
      pool_mod = Module.new
      allow(pool_mod).to receive(:connection_for).with('github').and_return(conn)
      stub_const('Legion::MCP::Client::Pool', pool_mod)

      # LEX runner returns matching result
      runner = double('PullRequest')
      allow(runner).to receive(:close).with(pr_id: 123).and_return({ closed: true })
      stub_const('Legion::Extensions::Github::Runners::PullRequest', runner)

      result = described_class.dispatch(tool_call: tool_call, source: source)

      # Primary result should be from MCP (user-facing)
      expect(result[:source][:type]).to eq(:mcp)
      expect(result[:status]).to eq(:success)
    end

    it 'records success when shadow results match' do
      tool_call = { name: 'close_pr', arguments: { pr_id: 123 } }
      source = { type: :mcp, server: 'github' }

      allow(Legion::Settings).to receive(:dig).with(:mcp, :overrides).and_return(nil)

      cap = double(extension: 'lex-github', runner: 'PullRequest', function: 'close')
      catalog_mod = Module.new
      allow(catalog_mod).to receive(:for_override).with('close_pr').and_return(cap)
      stub_const('Legion::Extensions::Catalog::Registry', catalog_mod)

      Legion::LLM::Tools::Confidence.record(
        tool: 'close_pr', lex: 'lex-github:PullRequest:close', confidence: 0.6
      )

      conn = double('Connection')
      allow(conn).to receive(:call_tool).and_return({
                                                      content: [{ type: 'text', text: '{"closed":true}' }]
                                                    })
      pool_mod = Module.new
      allow(pool_mod).to receive(:connection_for).with('github').and_return(conn)
      stub_const('Legion::MCP::Client::Pool', pool_mod)

      runner = double('PullRequest')
      allow(runner).to receive(:close).with(pr_id: 123).and_return({ closed: true })
      stub_const('Legion::Extensions::Github::Runners::PullRequest', runner)

      described_class.dispatch(tool_call: tool_call, source: source)

      entry = Legion::LLM::Tools::Confidence.lookup('close_pr')
      expect(entry[:confidence]).to be > 0.6
    end

    it 'records failure when shadow LEX errors' do
      tool_call = { name: 'close_pr', arguments: { pr_id: 123 } }
      source = { type: :mcp, server: 'github' }

      allow(Legion::Settings).to receive(:dig).with(:mcp, :overrides).and_return(nil)

      cap = double(extension: 'lex-github', runner: 'PullRequest', function: 'close')
      catalog_mod = Module.new
      allow(catalog_mod).to receive(:for_override).with('close_pr').and_return(cap)
      stub_const('Legion::Extensions::Catalog::Registry', catalog_mod)

      Legion::LLM::Tools::Confidence.record(
        tool: 'close_pr', lex: 'lex-github:PullRequest:close', confidence: 0.6
      )

      conn = double('Connection')
      allow(conn).to receive(:call_tool).and_return({
                                                      content: [{ type: 'text', text: '{"closed":true}' }]
                                                    })
      pool_mod = Module.new
      allow(pool_mod).to receive(:connection_for).with('github').and_return(conn)
      stub_const('Legion::MCP::Client::Pool', pool_mod)

      runner = double('PullRequest')
      allow(runner).to receive(:close).and_raise(StandardError, 'runner failed')
      stub_const('Legion::Extensions::Github::Runners::PullRequest', runner)

      described_class.dispatch(tool_call: tool_call, source: source)

      entry = Legion::LLM::Tools::Confidence.lookup('close_pr')
      expect(entry[:confidence]).to be < 0.6
    end

    it 'skips shadow when no Catalog match exists' do
      tool_call = { name: 'list_files', arguments: {} }
      source = { type: :mcp, server: 'filesystem' }

      allow(Legion::Settings).to receive(:dig).with(:mcp, :overrides).and_return(nil)

      Legion::LLM::Tools::Confidence.record(
        tool: 'list_files', lex: 'lex-fs:Dir:list', confidence: 0.6
      )

      catalog_mod = Module.new
      allow(catalog_mod).to receive(:for_override).with('list_files').and_return(nil)
      stub_const('Legion::Extensions::Catalog::Registry', catalog_mod)

      conn = double('Connection')
      allow(conn).to receive(:call_tool).and_return({
                                                      content: [{ type: 'text', text: '[]' }]
                                                    })
      pool_mod = Module.new
      allow(pool_mod).to receive(:connection_for).with('filesystem').and_return(conn)
      stub_const('Legion::MCP::Client::Pool', pool_mod)

      result = described_class.dispatch(tool_call: tool_call, source: source)
      expect(result[:source][:type]).to eq(:mcp)
    end
  end
end
