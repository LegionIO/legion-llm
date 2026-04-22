# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::McpDiscovery do
  let(:klass) do
    Class.new do
      include Legion::LLM::Inference::Steps::McpDiscovery

      attr_accessor :request, :enrichments, :timeline, :warnings, :discovered_tools

      def initialize(request)
        @request = request
        @enrichments = {}
        @timeline = Legion::LLM::Inference::Timeline.new
        @warnings = []
        @discovered_tools = []
      end
    end
  end

  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'list files' }],
      tools:    []
    )
  end

  describe '#step_mcp_discovery' do
    it 'discovers tools from MCP servers' do
      pool_mod = Module.new
      allow(pool_mod).to receive(:all_tools).and_return([
                                                          { name: 'list_files', description: 'List files in directory',
                                                            input_schema: { properties: { path: { type: 'string' } } },
                                                            source: { type: :mcp, server: 'filesystem' } }
                                                        ])
      stub_const('Legion::MCP::Client::Pool', pool_mod)

      step = klass.new(request)
      step.step_mcp_discovery

      expect(step.discovered_tools.size).to eq(1)
      expect(step.discovered_tools.first[:name]).to eq('list_files')
      expect(step.enrichments).to have_key('tool:discovery')
    end

    it 'skips when MCP Client not available' do
      hide_const('Legion::MCP::Client') if defined?(Legion::MCP::Client)

      step = klass.new(request)
      step.step_mcp_discovery

      expect(step.discovered_tools).to be_empty
    end

    it 'records timeline event' do
      pool_mod = Module.new
      allow(pool_mod).to receive(:all_tools).and_return([])
      stub_const('Legion::MCP::Client::Pool', pool_mod)

      step = klass.new(request)
      step.step_mcp_discovery

      keys = step.timeline.events.map { |e| e[:key] }
      expect(keys).to include('tool:discovery')
    end
  end
end
