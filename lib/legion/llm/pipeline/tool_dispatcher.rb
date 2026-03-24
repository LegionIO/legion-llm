# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module ToolDispatcher
        module_function

        def dispatch(tool_call:, source:, exchange_id: nil)
          start_time = Time.now

          # Check for settings override (LEX replaces MCP)
          if source[:type] == :mcp
            override = check_override(tool_call[:name])
            if override
              overridden_source = source
              source = override.merge(overridden_from: overridden_source)
            end
          end

          result = case source[:type]
                   when :mcp
                     dispatch_mcp(tool_call, source)
                   when :extension
                     dispatch_extension(tool_call, source)
                   when :builtin
                     dispatch_builtin(tool_call, source)
                   else
                     { status: :error, error: "Unknown tool source type: #{source[:type]}" }
                   end

          result.merge(
            source:      source,
            exchange_id: exchange_id,
            duration_ms: ((Time.now - start_time) * 1000).to_i
          )
        rescue StandardError => e
          { status: :error, error: e.message, source: source, exchange_id: exchange_id }
        end

        def check_override(tool_name)
          overrides = Legion::Settings.dig(:mcp, :overrides) rescue nil # rubocop:disable Style/RescueModifier
          return nil unless overrides.is_a?(Hash)

          override = overrides[tool_name]
          return nil unless override

          {
            type:     :extension,
            lex:      override[:lex] || override['lex'],
            runner:   override[:runner] || override['runner'],
            function: override[:function] || override['function']
          }
        end

        def dispatch_mcp(tool_call, source)
          conn = ::Legion::MCP::Client::Pool.connection_for(source[:server])
          raise "No connection for MCP server: #{source[:server]}" unless conn

          raw = conn.call_tool(name: tool_call[:name], arguments: tool_call[:arguments] || {})
          content = raw[:content]&.map { |c| c[:text] || c['text'] }&.join("\n")
          { status: raw[:error] ? :error : :success, result: content }
        end

        def dispatch_extension(tool_call, source)
          segments = (source[:lex] || '').delete_prefix('lex-').split('-')
          runner_path = (%w[Legion Extensions] + segments.map(&:capitalize) + ['Runners', source[:runner]]).join('::')

          runner = Kernel.const_get(runner_path)
          fn = source[:function].to_sym
          result = runner.send(fn, **(tool_call[:arguments] || {}))
          { status: :success, result: result }
        end

        def dispatch_builtin(_tool_call, _source)
          { status: :passthrough, result: nil }
        end
      end
    end
  end
end
