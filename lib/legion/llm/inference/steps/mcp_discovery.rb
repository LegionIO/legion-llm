# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module McpDiscovery
          include Legion::Logging::Helper

          def step_mcp_discovery
            @discovered_tools ||= []
            start_time = Time.now

            discover_server_tools
            discover_client_tools

            total = @discovered_tools.size
            if total.positive?
              sources = @discovered_tools.filter_map { |t| t.dig(:source, :server) || t.dig(:source, :type) }.uniq
              @enrichments['mcp:tool_discovery'] = {
                content:   "#{total} tools from #{sources.length} sources",
                data:      { tool_count: total, sources: sources },
                timestamp: Time.now
              }
            end

            record_mcp_timeline(total, start_time)
          rescue StandardError => e
            @warnings << "MCP discovery error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.mcp_discovery')
            record_mcp_timeline(0)
          end

          private

          def discover_server_tools
            server = mcp_server
            return unless server.respond_to?(:tool_registry)

            server.tool_registry.each do |tool_class|
              name = tool_class.respond_to?(:tool_name) ? tool_class.tool_name : tool_class.name
              desc = tool_class.respond_to?(:description) ? tool_class.description : ''
              schema = tool_class.respond_to?(:input_schema) ? tool_class.input_schema : {}
              @discovered_tools << {
                name:        name,
                description: desc,
                parameters:  schema,
                source:      { type: :server, server: 'legion' }
              }
            end

            log.info(
              "[llm][mcp] discover request_id=#{@request.id} " \
              "server_tools=#{server.tool_registry.size}"
            )
          rescue StandardError => e
            @warnings << "Server tool discovery error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.mcp_discovery.server')
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
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.mcp_discovery.client')
          end

          def record_mcp_timeline(count, start_time = nil)
            duration = start_time ? ((Time.now - start_time) * 1000).to_i : 0
            @timeline.record(
              category: :enrichment, key: 'mcp:tool_discovery',
              direction: :inbound, detail: "#{count} MCP tools discovered",
              from: 'mcp_client', to: 'pipeline',
              duration_ms: duration
            )
          end

          def mcp_server
            return ::Legion::MCP.server if defined?(::Legion::MCP) && ::Legion::MCP.respond_to?(:server)

            require 'legion/mcp'
            return unless defined?(::Legion::MCP) && ::Legion::MCP.respond_to?(:server)

            ::Legion::MCP.server
          rescue LoadError => e
            @warnings << "MCP unavailable: #{e.message}"
            handle_exception(e, level: :debug, operation: 'llm.pipeline.steps.mcp_discovery.mcp_server.require')
            nil
          rescue StandardError => e
            @warnings << "MCP server load error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.mcp_discovery.mcp_server')
            nil
          end
        end
      end
    end
  end
end
