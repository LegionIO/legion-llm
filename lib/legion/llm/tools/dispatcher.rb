# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/tools/interceptor'
require 'legion/llm/tools/special'

module Legion
  module LLM
    module Tools
      module Dispatcher
        extend Legion::Logging::Helper

        module_function

        def dispatch(tool_call:, source:, exchange_id: nil)
          start_time = Time.now
          log.debug "[llm][tools_dispatcher] action=dispatch.enter tool=#{tool_call[:name]} source_type=#{source[:type]} exchange_id=#{exchange_id}"

          if source[:type] == :mcp
            override = check_override(tool_call[:name])
            if override
              log.warn "[llm][tools_dispatcher] action=source_overridden tool=#{tool_call[:name]} from=mcp:#{source[:server]} to=#{override[:type]}"
              overridden_source = source
              source = override.merge(overridden_from: overridden_source)
            end
          end

          log.info "[llm][tools_dispatcher] action=dispatch_path tool=#{tool_call[:name]} path=#{source[:type]} exchange_id=#{exchange_id}"
          result = case source[:type]
                   when :mcp
                     dispatch_mcp(tool_call, source)
                   when :extension
                     dispatch_extension(tool_call, source)
                   when :registry
                     dispatch_registry(tool_call, source)
                   when :client
                     dispatch_client(tool_call, source)
                   when :special
                     dispatch_special(tool_call)
                   when :builtin
                     dispatch_builtin(tool_call, source)
                   else
                     { status: :error, error: "Unknown tool source type: #{source[:type]}" }
                   end

          duration_ms = ((Time.now - start_time) * 1000).to_i
          if result[:status] == :error
            err_detail = error_log_detail(result)
            log.warn "[llm][tools_dispatcher] action=dispatch_failed tool=#{tool_call[:name]} " \
                     "path=#{source[:type]} duration_ms=#{duration_ms} error=#{err_detail}"
          else
            log.info "[llm][tools_dispatcher] action=dispatch.complete tool=#{tool_call[:name]} " \
                     "path=#{source[:type]} status=#{result[:status]} duration_ms=#{duration_ms}"
          end
          result.merge(
            source:      source,
            exchange_id: exchange_id,
            duration_ms: duration_ms
          )
        rescue StandardError => e
          duration_ms = ((Time.now - start_time) * 1000).to_i
          err_detail = trim_error_detail("#{e.class}:#{e.message}")
          log.warn "[llm][tools_dispatcher] action=dispatch_exception tool=#{tool_call[:name]} " \
                   "path=#{source&.[](:type)} duration_ms=#{duration_ms} error=#{err_detail}"
          handle_exception(e, level: :warn, operation: 'llm.tools.dispatcher.dispatch_tool_call', tool_name: tool_call[:name])
          { status: :error, error: e.message, source: source, exchange_id: exchange_id, duration_ms: duration_ms }
        end

        def check_override(tool_name)
          settings_override = check_settings_override(tool_name)
          return settings_override if settings_override

          check_registry_override(tool_name)
        end

        def check_registry_override(tool_name)
          return nil unless Legion::Settings::Extensions.respond_to?(:find_tool)

          entry = Legion::Settings::Extensions.find_tool(tool_name)
          return nil unless entry

          if entry[:tool_class]
            { type: :registry, tool_class: entry[:tool_class] }
          elsif entry[:extension] && entry[:runner] && entry[:function]
            { type: :extension, lex: entry[:extension], runner: entry[:runner], function: entry[:function] }
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.tools.dispatcher.check_registry_override', tool_name: tool_name)
          nil
        end

        def check_settings_override(tool_name)
          overrides = Legion::Settings.dig(:mcp, :overrides)
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
          log.debug "[llm][tools] action=dispatch_mcp tool=#{tool_call[:name]} server=#{source[:server]}"
          conn = ::Legion::MCP::Client::Pool.connection_for(source[:server])
          raise "No connection for MCP server: #{source[:server]}" unless conn

          raw = conn.call_tool(name: tool_call[:name], arguments: tool_call[:arguments] || {})
          content = raw[:content]&.map { |c| c[:text] || c['text'] }&.join("\n")
          { status: raw[:error] ? :error : :success, result: content }
        end

        def dispatch_extension(tool_call, source)
          lex = source[:lex] || source[:extension]
          log.debug "[llm][tools] action=dispatch_extension tool=#{tool_call[:name]} lex=#{lex} runner=#{source[:runner]}"
          segments = (lex || '').delete_prefix('lex-').split('-')
          runner_path = (%w[Legion Extensions] + segments.map(&:capitalize) + ['Runners', source[:runner]]).join('::')

          runner = Kernel.const_get(runner_path)
          fn = source[:function].to_sym
          result = runner.send(fn, **symbolize_keys(tool_call[:arguments] || {}))
          { status: :success, result: result }
        end

        def dispatch_registry(tool_call, source)
          log.debug "[llm][tools] action=dispatch_registry tool=#{tool_call[:name]}"
          tool_class = source[:tool_class]
          raise "No registry tool class for #{tool_call[:name]}" unless tool_class.respond_to?(:call)

          args = symbolize_keys(tool_call[:arguments] || {})
          args = Interceptor.intercept(tool_call[:name], **args)
          result = tool_class.call(**args)
          { status: result_error?(result) ? :error : :success, result: extract_content(result) }
        end

        def dispatch_client(tool_call, source)
          { status: :passthrough, result: nil, client_tool: true, tool_name: tool_call[:name], source: source }
        end

        def dispatch_special(tool_call)
          Special.dispatch(tool_call[:name], **symbolize_keys(tool_call[:arguments] || {}))
        end

        def dispatch_builtin(_tool_call, _source)
          { status: :passthrough, result: nil }
        end

        def symbolize_keys(value)
          case value
          when Hash
            value.to_h do |key, nested|
              normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
              [normalized_key, symbolize_keys(nested)]
            end
          when Array
            value.map { |entry| symbolize_keys(entry) }
          else
            value
          end
        end

        def extract_content(result)
          if result.respond_to?(:content) && result.content.is_a?(Array)
            result.content.filter_map { |c| c[:text] || c['text'] || c.to_s }.join("\n")
          elsif result.is_a?(Hash) && result[:content].is_a?(Array)
            result[:content].filter_map { |c| c[:text] || c['text'] }.join("\n")
          elsif result.is_a?(Hash)
            Legion::JSON.dump(result)
          elsif result.is_a?(String)
            result
          else
            result.to_s
          end
        end

        def result_error?(result)
          result.is_a?(Hash) && (result[:error] || result['error'])
        end

        def error_log_detail(result)
          detail = structured_error_detail(result)
          detail = result_value(result, :error).to_s if detail.empty?
          detail = result_value(result, :result).to_s if detail.empty?
          trim_error_detail(detail)
        end

        def structured_error_detail(result)
          fields = []
          exit_status = result_value(result, :exit_status)
          error = result_value(result, :error)
          output_tail = result_value(result, :output_tail)
          command_preview = result_value(result, :command_preview)

          fields << "exit_status=#{exit_status}" unless exit_status.nil?
          fields << "error=#{single_line(error)}" unless error.to_s.empty?
          fields << "output_tail=#{single_line(output_tail)}" unless output_tail.to_s.empty?
          fields << "command_preview=#{single_line(command_preview)}" if fields.empty? && !command_preview.to_s.empty?
          fields.join(' ')
        end

        def result_value(result, key)
          return nil unless result.respond_to?(:[])

          result[key] || result[key.to_s]
        end

        def single_line(value)
          value.to_s.gsub(/\s+/, ' ').strip
        end

        def trim_error_detail(value)
          value.to_s[0, tool_error_log_chars]
        end

        def tool_error_log_chars
          configured = Legion::Settings[:llm][:tool_error_log_chars].to_i
          configured.positive? ? configured : 500
        rescue StandardError
          500
        end
      end
    end
  end
end
