# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Steps
        module McpDiscovery
          def step_mcp_discovery
            @discovered_tools ||= []

            unless defined?(::Legion::MCP::Client::Pool)
              @warnings << 'MCP Client unavailable for tool discovery'
              record_mcp_timeline(0)
              return
            end

            start_time = Time.now
            mcp_tools = ::Legion::MCP::Client::Pool.all_tools

            mcp_tools.each do |tool|
              @discovered_tools << {
                name: tool[:name],
                description: tool[:description],
                parameters: tool[:input_schema],
                source: tool[:source]
              }
            end

            if mcp_tools.any?
              servers = mcp_tools.map { |t| t.dig(:source, :server) }.uniq
              @enrichments['mcp:tool_discovery'] = {
                content: "#{mcp_tools.length} tools from #{servers.length} servers",
                data: { tool_count: mcp_tools.length, servers: servers },
                timestamp: Time.now
              }
            end

            record_mcp_timeline(mcp_tools.length, start_time)
          rescue StandardError => e
            @warnings << "MCP discovery error: #{e.message}"
            record_mcp_timeline(0)
          end

          private

          def record_mcp_timeline(count, start_time = nil)
            duration = start_time ? ((Time.now - start_time) * 1000).to_i : 0
            @timeline.record(
              category: :enrichment, key: 'mcp:tool_discovery',
              direction: :inbound, detail: "#{count} MCP tools discovered",
              from: 'mcp_client', to: 'pipeline',
              duration_ms: duration
            )
          end
        end
      end
    end
  end
end
