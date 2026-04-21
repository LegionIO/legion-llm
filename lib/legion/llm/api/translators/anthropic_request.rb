# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Translators
        module AnthropicRequest
          extend Legion::Logging::Helper

          # Normalize Anthropic Messages API request into internal format.
          #
          # Key differences from OpenAI:
          #   - system is a top-level param, not a messages entry
          #   - tools use input_schema not parameters
          #   - max_tokens is required per Anthropic spec
          def self.normalize(body)
            log.debug('[llm][translator][anthropic_request] action=normalize')

            messages = extract_messages(body)
            system   = extract_system(body)
            tools    = extract_tools(body)
            routing  = extract_routing(body)

            result = {
              messages:   messages,
              tools:      tools,
              routing:    routing,
              stream:     body[:stream] == true,
              max_tokens: body[:max_tokens],
              metadata:   { anthropic_version: body[:anthropic_version] }
            }
            result[:system] = system if system
            result.compact
          end

          def self.extract_messages(body)
            raw = body[:messages] || []
            raw.map do |m|
              role    = (m[:role] || m['role']).to_sym
              content = m[:content] || m['content']
              { role: role, content: normalize_content(content) }
            end
          end

          def self.extract_system(body)
            sys = body[:system]
            return nil if sys.nil?
            return sys if sys.is_a?(String)

            # system can be a string or array of content blocks
            if sys.is_a?(Array)
              text_blocks = sys.select { |b| (b[:type] || b['type']).to_s == 'text' }
              text_blocks.map { |b| b[:text] || b['text'] }.join("\n\n")
            else
              sys.to_s
            end
          end

          def self.extract_tools(body)
            raw = body[:tools]
            return [] unless raw.is_a?(Array)

            raw.map do |t|
              ts = t.respond_to?(:transform_keys) ? t.transform_keys(&:to_sym) : t
              {
                name:        ts[:name].to_s,
                description: ts[:description].to_s,
                # Anthropic uses input_schema, not parameters
                parameters:  ts[:input_schema] || ts[:parameters] || {}
              }
            end
          end

          def self.extract_routing(body)
            {
              model:    body[:model],
              provider: :anthropic
            }
          end

          def self.normalize_content(content)
            return content if content.is_a?(String)
            return content unless content.is_a?(Array)

            content.map do |block|
              bs = block.respond_to?(:transform_keys) ? block.transform_keys(&:to_sym) : block
              type = bs[:type].to_s
              case type
              when 'text'
                bs[:text].to_s
              when 'tool_result'
                { type: :tool_result, tool_use_id: bs[:tool_use_id], content: bs[:content] }
              when 'tool_use'
                { type: :tool_use, id: bs[:id], name: bs[:name], input: bs[:input] }
              else
                bs
              end
            end.then { |parts| parts.all? { |p| p.is_a?(String) } ? parts.join : parts }
          end

          private_class_method :extract_messages, :extract_system, :extract_tools,
                                :extract_routing, :normalize_content
        end
      end
    end
  end
end
