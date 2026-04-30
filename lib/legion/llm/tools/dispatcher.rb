# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/tools/interceptor'

module Legion
  module LLM
    module Tools
      module Dispatcher
        extend Legion::Logging::Helper

        module_function

        def dispatch(tool_call:, source:, exchange_id: nil)
          start_time = Time.now

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
                   when :registry
                     dispatch_registry(tool_call, source)
                   when :client
                     dispatch_client(tool_call, source)
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
          handle_exception(e, level: :warn, operation: 'llm.tools.dispatcher.dispatch_tool_call', tool_name: tool_call[:name])
          { status: :error, error: e.message, source: source, exchange_id: exchange_id }
        end

        def check_override(tool_name)
          registry_override = check_registry_override(tool_name)
          return registry_override if registry_override

          check_settings_override(tool_name)
        end

        def check_registry_override(tool_name)
          return nil unless defined?(Legion::Settings::Extensions) &&
                            Legion::Settings::Extensions.respond_to?(:find_tool)

          entry = Legion::Settings::Extensions.find_tool(tool_name)
          return nil unless entry

          if entry[:tool_class]
            { type: :registry, tool_class: entry[:tool_class] }
          elsif entry[:extension] && entry[:runner] && entry[:function]
            { type: :extension, lex: entry[:extension], runner: entry[:runner], function: entry[:function] }
          end
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.tools.dispatcher.check_registry_override', tool_name: tool_name)
          nil
        end

        def check_settings_override(tool_name)
          overrides = Legion::LLM::Settings.global_value(:mcp, :overrides)
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

        def dispatch_registry(tool_call, source)
          tool_class = source[:tool_class]
          raise "No registry tool class for #{tool_call[:name]}" unless tool_class.respond_to?(:call)

          args = symbolize_keys(tool_call[:arguments] || {})
          args = Interceptor.intercept(tool_call[:name], **args)
          result = tool_class.call(**args)
          { status: result_error?(result) ? :error : :success, result: extract_content(result) }
        end

        def dispatch_client(tool_call, source)
          return { status: :error, result: "Tool #{tool_call[:name]} is not executable server-side." } unless source[:executable]

          require 'legion/llm/api/native/helpers'

          helper = Object.new.extend(Legion::LLM::API::Native::ClientToolMethods)
          result = helper.send(:dispatch_client_tool, tool_call[:name].to_s, **symbolize_keys(tool_call[:arguments] || {}))
          { status: :success, result: result }
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
      end
    end
  end
end
