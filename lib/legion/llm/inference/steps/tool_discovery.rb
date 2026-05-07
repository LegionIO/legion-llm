# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module ToolDiscovery
          include Legion::Logging::Helper
          include Steps::Logging

          def step_tool_discovery
            @discovered_tools ||= []
            start_time = Time.now
            log_step_debug(:tool_discovery, :start, existing_tool_count: @discovered_tools.size)

            discover_registry_tools
            discover_client_tools

            total = @discovered_tools.size
            if total.positive?
              sources = @discovered_tools.filter_map { |t| t.dig(:source, :server) || t.dig(:source, :type) }.uniq
              @enrichments['tool:discovery'] = {
                content:   "#{total} tools from #{sources.length} sources",
                data:      { tool_count: total, sources: sources },
                timestamp: Time.now
              }
            end

            record_tool_discovery_timeline(total, start_time)
            log_step_debug(:tool_discovery, :complete, tool_count: total)
          rescue StandardError => e
            @warnings << "Tool discovery error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.tool_discovery')
            record_tool_discovery_timeline(0)
          end

          # Backwards compatibility alias — step name used in STEPS array is tool_discovery
          alias step_mcp_discovery step_tool_discovery

          private

          def discover_registry_tools
            unless Legion::Settings::Extensions.respond_to?(:tools) &&
                   Legion::Settings::Extensions.respond_to?(:filter_tools)
              log_step_debug(:tool_discovery, :registry_skipped, reason: :settings_extensions_unavailable)
              return
            end
            unless Array(Legion::Settings::Extensions.tools).any?
              log_step_debug(:tool_discovery, :registry_skipped, reason: :no_registered_tools)
              return
            end

            discover_settings_extensions_tools
          rescue StandardError => e
            @warnings << "Registry tool discovery error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.tool_discovery.registry')
          end

          def discover_settings_extensions_tools
            entries = Legion::Settings::Extensions.filter_tools(deferred: false)
            log_step_debug(:tool_discovery, :registry_scan, candidate_count: entries.size)
            entries.each do |entry|
              @discovered_tools << {
                name:        entry[:name],
                description: entry[:description] || '',
                parameters:  entry[:input_schema] || entry[:parameters] || {},
                source:      build_entry_source(entry)
              }
            end

            log.info(
              "[llm][tools] discover request_id=#{@request.id} " \
              "settings_extensions_tools=#{entries.size}"
            )
          end

          def build_entry_source(entry)
            if entry[:tool_class]
              { type: :registry, tool_class: entry[:tool_class] }
            elsif entry[:extension] && entry[:runner] && entry[:function]
              { type: :extension, lex: entry[:extension], runner: entry[:runner], function: entry[:function] }
            else
              { type: :registry, server: 'legion' }
            end
          end

          def discover_client_tools
            unless defined?(::Legion::MCP::Client::Pool)
              log_step_debug(:tool_discovery, :client_skipped, reason: :mcp_client_pool_unavailable)
              return
            end

            tools = ::Legion::MCP::Client::Pool.all_tools
            log_step_debug(:tool_discovery, :client_scan, candidate_count: tools.size)
            tools.each do |tool|
              @discovered_tools << {
                name:        tool[:name],
                description: tool[:description],
                parameters:  tool[:input_schema],
                source:      tool[:source]
              }
            end
          rescue StandardError => e
            @warnings << "Client tool discovery error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.tool_discovery.client')
          end

          def record_tool_discovery_timeline(count, start_time = nil)
            duration = start_time ? ((Time.now - start_time) * 1000).to_i : 0
            @timeline.record(
              category: :enrichment, key: 'tool:discovery',
              direction: :inbound, detail: "#{count} tools discovered",
              from: 'tool_registry', to: 'pipeline',
              duration_ms: duration
            )
          end
        end

        # Backwards compatibility alias
        McpDiscovery = ToolDiscovery
      end
    end
  end
end
