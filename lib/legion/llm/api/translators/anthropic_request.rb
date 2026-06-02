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
            raw.flat_map { |m| normalize_message(m) }
          end

          def self.normalize_message(msg)
            role    = (msg[:role] || msg['role']).to_sym
            content = msg[:content] || msg['content']

            case role
            when :assistant
              normalize_assistant_message(content)
            when :user
              normalize_user_message(content)
            else
              [{ role: role, content: extract_text_content(content) }]
            end
          end

          def self.normalize_assistant_message(content)
            return [{ role: :assistant, content: content }] if content.is_a?(String)
            return [{ role: :assistant, content: content.to_s }] unless content.is_a?(Array)

            text_parts = []
            tool_calls = []

            content.each do |block|
              bs = block.respond_to?(:transform_keys) ? block.transform_keys(&:to_sym) : block
              type = (bs[:type] || '').to_s
              case type
              when 'text'
                text_parts << bs[:text].to_s
              when 'tool_use'
                tool_calls << { id: bs[:id], name: bs[:name], arguments: bs[:input] || {} }
              end
            end

            msg = { role: :assistant, content: text_parts.join("\n\n") }
            msg[:tool_calls] = tool_calls if tool_calls.any?
            [msg]
          end

          def self.normalize_user_message(content)
            return [{ role: :user, content: content }] if content.is_a?(String)
            return [{ role: :user, content: content.to_s }] unless content.is_a?(Array)

            messages = []
            text_parts = []

            content.each do |block|
              bs = block.respond_to?(:transform_keys) ? block.transform_keys(&:to_sym) : block
              type = (bs[:type] || '').to_s
              case type
              when 'text'
                text_parts << bs[:text].to_s
              when 'tool_result'
                if text_parts.any?
                  messages << { role: :user, content: text_parts.join("\n\n") }
                  text_parts = []
                end
                result_content = bs[:content]
                messages << if result_content.is_a?(Array)
                              { role: :tool, tool_call_id: bs[:tool_use_id], content: result_content }
                            else
                              { role: :tool, tool_call_id: bs[:tool_use_id], content: result_content.to_s }
                            end
              else
                text_parts << bs.to_s
              end
            end

            messages << { role: :user, content: text_parts.join } if text_parts.any?
            messages.empty? ? [{ role: :user, content: '' }] : messages
          end

          def self.extract_text_content(content)
            return content if content.is_a?(String)
            return content.to_s unless content.is_a?(Array)

            content.filter_map do |block|
              bs = block.respond_to?(:transform_keys) ? block.transform_keys(&:to_sym) : block
              bs[:text].to_s if (bs[:type] || '').to_s == 'text'
            end.join
          end

          def self.extract_system(body)
            sys = body[:system]
            return nil if sys.nil?
            return sys if sys.is_a?(String)

            if sys.is_a?(Array)
              has_cache_control = sys.any? { |b| b[:cache_control] || b['cache_control'] }
              if has_cache_control
                sys.filter_map do |b|
                  next unless (b[:type] || b['type']).to_s == 'text'

                  { text: b[:text] || b['text'], cache_control: b[:cache_control] || b['cache_control'] }.compact
                end
              else
                text_blocks = sys.select { |b| (b[:type] || b['type']).to_s == 'text' }
                text_blocks.map { |b| b[:text] || b['text'] }.join("\n\n")
              end
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
              model: body[:model]
            }
          end

          private_class_method :extract_messages, :extract_system, :extract_tools,
                               :extract_routing, :normalize_message, :normalize_assistant_message,
                               :normalize_user_message, :extract_text_content
        end
      end
    end
  end
end
