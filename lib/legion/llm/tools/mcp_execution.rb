# frozen_string_literal: true

require 'mcp'
require 'legion/json'
require 'legion/logging/helper'
require 'legion/mcp/tool_adapter'
require 'legion/mcp/version'
require_relative 'dispatcher'

module Legion
  module LLM
    module Tools
      # A request-local MCP SDK boundary around the daemon's existing handlers.
      # No HTTP transport, daemon API re-entry, global MCP catalog rebuild, or
      # client-owned tool execution. Discovery and source resolution stay with
      # the executor; the SDK validates the resolved definition before dispatch.
      module MCPExecution
        extend Legion::Logging::Helper

        LOCAL_SOURCES = %i[special registry extension].freeze
        SERVER_LABEL = 'legion'

        module_function

        def metadata_for(source)
          type = source&.[](:type)
          label = type == :mcp ? source[:server] : SERVER_LABEL
          return {} unless LOCAL_SOURCES.include?(type) || type == :mcp
          raise ArgumentError, 'MCP execution requires a server label' if label.to_s.empty?

          { mcp_server_label: label.to_s }
        end

        def dispatch(tool_call:, source:, definition:, exchange_id: nil)
          return Dispatcher.dispatch(tool_call: tool_call, source: source, exchange_id: exchange_id) unless LOCAL_SOURCES.include?(source[:type])
          raise ArgumentError, "Missing tool definition for #{tool_call[:name]}" unless definition

          execution = nil
          tool = adapter_for(definition) do |arguments|
            execution = Dispatcher.dispatch(tool_call: tool_call.merge(arguments: arguments), source: source, exchange_id: exchange_id)
            output = execution.key?(:result) ? execution[:result] : execution[:error]
            output = Legion::JSON.dump(output) unless output.is_a?(String)
            { content: [{ type: 'text', text: output }], error: execution[:status] == :error }
          end
          server = ::MCP::Server.new(name: SERVER_LABEL, version: Legion::MCP::VERSION, tools: [tool])
          request = { jsonrpc: '2.0', id: tool_call[:id], method: 'tools/call',
                      params: { name: tool.tool_name, arguments: tool_call[:arguments] || {} } }
          response = Legion::JSON.load(server.handle_json(Legion::JSON.dump(request)))
          if response[:error]
            return { status: :error, error: response[:error][:message], result: response[:error][:message],
                     source: source, exchange_id: exchange_id }
          end

          result = response.fetch(:result)
          output = result.fetch(:content).map { |part| part.fetch(:text) }.join("\n")
          (execution || {}).merge(status: result[:isError] ? :error : :success, result: output,
                                  source: source, exchange_id: exchange_id)
        end

        def adapter_for(definition, &execute)
          tool_class = Class.new do
            define_singleton_method(:tool_name) { definition.name }
            define_singleton_method(:description) { definition.description }
            define_singleton_method(:input_schema) { definition.parameters }
            define_singleton_method(:call) do |server_context: nil, **arguments|
              _ = server_context # MCP SDK context is not part of the tool's arguments.
              execute.call(arguments)
            end
          end
          Legion::MCP::ToolAdapter.from_legion_tool(tool_class)
        end
        private_class_method :adapter_for
      end
    end
  end
end
