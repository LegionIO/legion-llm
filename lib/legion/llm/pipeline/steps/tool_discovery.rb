# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
      module Steps
        module ToolDiscovery
          include Legion::Logging::Helper

          def step_tool_discovery
            @discovered_tools ||= []
            start_time = Time.now

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
          rescue StandardError => e
            @warnings << "Tool discovery error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.tool_discovery')
            record_tool_discovery_timeline(0)
          end

          # Backwards compatibility alias — step name used in STEPS array is tool_discovery
          alias step_mcp_discovery step_tool_discovery

          private

          def discover_registry_tools
            return unless defined?(::Legion::Tools::Registry)

            ::Legion::Tools::Registry.tools.each do |tool_class|
              name = tool_class.respond_to?(:tool_name) ? tool_class.tool_name : tool_class.name
              desc = tool_class.respond_to?(:description) ? tool_class.description : ''
              schema = tool_class.respond_to?(:input_schema) ? tool_class.input_schema : {}
              @discovered_tools << {
                name:        name,
                description: desc,
                parameters:  schema,
                source:      { type: :registry, server: 'legion' }
              }
            end

            log.info(
              "[llm][tools] discover request_id=#{@request.id} " \
              "registry_tools=#{::Legion::Tools::Registry.tools.size}"
            )
          rescue StandardError => e
            @warnings << "Registry tool discovery error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.tool_discovery.registry')
          end

          def discover_client_tools
            return unless defined?(::Legion::MCP::Client::Pool)

            ::Legion::MCP::Client::Pool.all_tools.each do |tool|
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
