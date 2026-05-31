# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::ToolCalls do
  let(:logger) { instance_double('Logger', debug: nil, info: nil) }

  let(:klass) do
    Class.new do
      include Legion::LLM::Inference::Steps::ToolCalls

      attr_accessor :request, :enrichments, :timeline, :warnings,
                    :discovered_tools, :raw_response, :exchange_id

      def initialize(request)
        @request = request
        @enrichments = {}
        @timeline = Legion::LLM::Inference::Timeline.new
        @warnings = []
        @discovered_tools = []
        @exchange_id = 'exch_001'
      end

      def llm_setting(key, default = nil)
        Legion::LLM::Settings.config_value(Legion::LLM::Settings.current_settings, key, default)
      rescue StandardError
        default
      end
    end
  end

  describe '#step_tool_calls' do
    before do
      allow_any_instance_of(klass).to receive(:log).and_return(logger)
    end

    it 'dispatches MCP tool calls via ToolDispatcher' do
      request = Legion::LLM::Inference::Request.build(id: 'req_tool_1', conversation_id: 'conv_tool_1', messages: [])
      step = klass.new(request)
      step.discovered_tools = [
        { name: 'list_files', source: { type: :mcp, server: 'filesystem' } }
      ]

      step.raw_response = double(
        content:    nil,
        tool_calls: [{ name: 'list_files', arguments: { path: '.' }, id: 'call_1' }]
      )
      allow(step.raw_response).to receive(:respond_to?).with(:tool_calls).and_return(true)

      dispatch_result = {
        status: :success, result: '["a.rb"]',
        source: { type: :mcp, server: 'filesystem' },
        duration_ms: 45
      }
      allow(Legion::LLM::Inference::ToolDispatcher).to receive(:dispatch).and_return(dispatch_result)

      step.step_tool_calls

      keys = step.timeline.events.map { |e| e[:key] }
      expect(keys).to include(match(/tool:execute/))
      expect(logger).to have_received(:info).with(
        include('[llm][tools] detected', 'request_id=req_tool_1', 'count=1')
      )
      expect(logger).to have_received(:info).with(
        include('[llm][tools] dispatch', 'request_id=req_tool_1', 'name=list_files', 'source=mcp:filesystem')
      )
      expect(logger).to have_received(:info).with(
        include('[llm][tools] result', 'request_id=req_tool_1', 'name=list_files', 'status=success')
      )
    end

    it 'skips when no tool calls in response' do
      request = Legion::LLM::Inference::Request.build(messages: [])
      step = klass.new(request)
      step.raw_response = double(content: 'just text')
      allow(step.raw_response).to receive(:respond_to?).with(:tool_calls).and_return(false)

      step.step_tool_calls
      expect(step.timeline.events).to be_empty
    end

    it 'passes non-executable client tool calls through without dispatching server-side' do
      request = Legion::LLM::Inference::Request.build(id: 'req_tool_2', conversation_id: 'conv_tool_2', messages: [])
      step = klass.new(request)
      step.instance_variable_set(:@native_tool_source_map, {
                                   'mcp_servers' => { type: :client, executable: false }
                                 })
      step.raw_response = double(
        content:    nil,
        tool_calls: [{ name: 'mcp_servers', arguments: '', id: 'call_1' }]
      )
      allow(step.raw_response).to receive(:respond_to?).with(:tool_calls).and_return(true)

      expect(Legion::LLM::Inference::ToolDispatcher).not_to receive(:dispatch)

      step.step_tool_calls

      expect(logger).to have_received(:info).with(
        include('[llm][tools] client_passthrough', 'request_id=req_tool_2', 'name=mcp_servers')
      )
    end
  end
end
