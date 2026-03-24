# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::ToolCalls do
  let(:klass) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::ToolCalls

      attr_accessor :request, :enrichments, :timeline, :warnings,
                    :discovered_tools, :raw_response, :exchange_id

      def initialize(request)
        @request = request
        @enrichments = {}
        @timeline = Legion::LLM::Pipeline::Timeline.new
        @warnings = []
        @discovered_tools = []
        @exchange_id = 'exch_001'
      end
    end
  end

  describe '#step_tool_calls' do
    it 'dispatches MCP tool calls via ToolDispatcher' do
      request = Legion::LLM::Pipeline::Request.build(messages: [])
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
      allow(Legion::LLM::Pipeline::ToolDispatcher).to receive(:dispatch).and_return(dispatch_result)

      step.step_tool_calls

      keys = step.timeline.events.map { |e| e[:key] }
      expect(keys).to include(match(/tool:execute/))
    end

    it 'skips when no tool calls in response' do
      request = Legion::LLM::Pipeline::Request.build(messages: [])
      step = klass.new(request)
      step.raw_response = double(content: 'just text')
      allow(step.raw_response).to receive(:respond_to?).with(:tool_calls).and_return(false)

      step.step_tool_calls
      expect(step.timeline.events).to be_empty
    end
  end
end
