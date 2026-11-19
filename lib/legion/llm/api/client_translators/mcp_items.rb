# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module ClientTranslators
        # Documented Responses MCP output items. Execution provenance comes from
        # canonical metadata; arbitrary direct Ruby calls are not relabeled MCP.
        module MCPItems
          include Legion::Logging::Helper

          private

          def mcp_item(id:, name:, arguments:, server_label:, result: nil, error: nil, status: nil)
            arguments = Legion::JSON.dump(arguments) unless arguments.is_a?(String)
            result = Legion::JSON.dump(result) unless result.nil? || result.is_a?(String)
            failed = !error.nil? && error != false
            {
              id: id, type: 'mcp_call', name: name, server_label: server_label,
              arguments: arguments, status: status || (failed ? 'failed' : 'completed'),
              output: result, error: failed ? { type: 'mcp_tool_execution_error', content: error } : nil
            }
          end
        end
      end
    end
  end
end
