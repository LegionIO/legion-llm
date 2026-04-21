# frozen_string_literal: true

require 'legion/logging/helper'

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
                     mcp_result = dispatch_mcp(tool_call, source)
                     run_shadow(tool_call, source, mcp_result)
                     mcp_result
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
          handle_exception(e, level: :warn, operation: 'llm.tools.dispatcher.dispatch_tool_call', tool_name: tool_call[:name])
          { status: :error, error: e.message, source: source, exchange_id: exchange_id }
        end

        def check_override(tool_name)
          settings_override = check_settings_override(tool_name)
          return settings_override if settings_override

          check_catalog_override(tool_name)
        end

        def check_settings_override(tool_name)
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

        def check_catalog_override(tool_name)
          return nil unless defined?(Legion::Extensions::Catalog::Registry)
          return nil unless Legion::LLM::Tools::Confidence.should_override?(tool_name)

          cap = Legion::Extensions::Catalog::Registry.for_override(tool_name)
          return nil unless cap

          {
            type:     :extension,
            lex:      cap.extension,
            runner:   cap.runner,
            function: cap.function
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

        def run_shadow(tool_call, _source, mcp_result)
          tool_name = tool_call[:name]
          return unless Legion::LLM::Tools::Confidence.should_shadow?(tool_name)
          return unless defined?(Legion::Extensions::Catalog::Registry)

          cap = Legion::Extensions::Catalog::Registry.for_override(tool_name)
          return unless cap

          shadow_source = { type: :extension, lex: cap.extension, runner: cap.runner, function: cap.function }
          shadow_result = dispatch_extension(tool_call, shadow_source)

          if shadow_result[:status] == :success && mcp_result[:status] == :success
            Legion::LLM::Tools::Confidence.record_success(tool_name)
          else
            Legion::LLM::Tools::Confidence.record_failure(tool_name)
          end
        rescue StandardError => e
          Legion::LLM::Tools::Confidence.record_failure(tool_name) if tool_name
          handle_exception(e, level: :debug, operation: 'llm.tools.dispatcher.shadow_execution', tool_name: tool_name)
        end
      end
    end
  end
end
