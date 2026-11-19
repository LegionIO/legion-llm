# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/json'

module Legion
  module LLM
    module API
      module ClientTranslators
        # OpenAI clients execute ordinary function calls regardless of their
        # completed status. Server executions therefore use visible assistant
        # content, preserving the exchange without requesting client execution.
        module ServerToolTranscript
          include Legion::Logging::Helper

          def server_tool_call_text(id:, name:, arguments:, **)
            arguments = Legion::JSON.load(arguments) if arguments.is_a?(String)
            record = { id: id, name: name, arguments: arguments }
            "\n\nLegionIO server tool call:\n#{Legion::JSON.dump(record)}\n"
          end

          def server_tool_result_text(id:, result:, **)
            text = result.is_a?(String) ? result : Legion::JSON.dump(result)
            "\nLegionIO server tool result (#{id}):\n#{text}\n\n"
          end

          def server_tool_exchange_text(tool_call:, **)
            server_tool_call_text(id: tool_call.id, name: tool_call.name, arguments: tool_call.arguments) +
              server_tool_result_text(id: tool_call.id, result: tool_call.result)
          end
        end
      end
    end
  end
end
