# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Translators
        module OpenAIRequest
          extend Legion::Logging::Helper

          module_function

          def normalize(body)
            log.debug('[llm][translator][openai_request] action=normalize')
            messages, system = extract_messages_and_system(body[:messages] || body['messages'] || [])
            tools = normalize_tools(body[:tools] || body['tools'])
            model = body[:model] || body['model']
            stream = body[:stream] || body['stream']
            max_tokens = body[:max_tokens] || body['max_tokens']
            temperature = body[:temperature] || body['temperature']

            result = {
              messages:    messages,
              model:       model,
              stream:      stream == true,
              max_tokens:  max_tokens,
              temperature: temperature,
              tools:       tools
            }
            result[:system] = system if system

            log.debug("[llm][translator][openai_request] action=normalized messages=#{messages.size} has_system=#{!system.nil?} tools=#{tools&.size || 0}")
            result.compact
          end

          def extract_messages_and_system(raw_messages)
            system_content = nil
            messages = []

            raw_messages.each do |msg|
              m = msg.respond_to?(:transform_keys) ? msg.transform_keys(&:to_sym) : msg
              role = (m[:role] || m['role']).to_sym

              case role
              when :system
                system_content = extract_content(m[:content])
              when :assistant
                entry = { role: role, content: extract_content(m[:content]) }
                entry[:tool_calls] = normalize_assistant_tool_calls(m[:tool_calls]) if m[:tool_calls]
                messages << entry
              when :tool
                messages << { role: role, content: extract_content(m[:content]), tool_call_id: m[:tool_call_id] }.compact
              else
                messages << { role: role, content: extract_content(m[:content]) }
              end
            end

            [messages, system_content]
          end

          def normalize_assistant_tool_calls(tool_calls)
            return nil unless tool_calls.is_a?(Array) && tool_calls.any?

            tool_calls.filter_map do |tc|
              tc = tc.transform_keys(&:to_sym) if tc.respond_to?(:transform_keys)
              fn = tc[:function]
              fn = fn.transform_keys(&:to_sym) if fn.respond_to?(:transform_keys)
              next unless fn.is_a?(Hash)

              {
                id:        tc[:id] || "call_#{fn[:name]}_#{SecureRandom.hex(8)}",
                name:      fn[:name].to_s,
                arguments: fn[:arguments].is_a?(String) ? Legion::JSON.parse(fn[:arguments]) : (fn[:arguments] || {})
              }
            rescue StandardError => e
              log.warn("[llm][translator][openai_request] action=normalize_tool_call error=#{e.message}")
              nil
            end
          end

          def extract_content(content)
            return content if content.is_a?(String)
            return content unless content.is_a?(Array)

            has_non_text = content.any? do |block|
              b = block.respond_to?(:transform_keys) ? block.transform_keys(&:to_sym) : block
              b[:type].to_s != 'text'
            end

            if has_non_text
              content.map { |block| block.respond_to?(:transform_keys) ? block.transform_keys(&:to_sym) : block }
            else
              content.filter_map do |block|
                b = block.respond_to?(:transform_keys) ? block.transform_keys(&:to_sym) : block
                b[:text] if b[:type].to_s == 'text'
              end.join
            end
          end

          def normalize_tools(raw_tools)
            return nil if raw_tools.nil? || !raw_tools.is_a?(Array) || raw_tools.empty?

            raw_tools.filter_map do |tool|
              t = tool.respond_to?(:transform_keys) ? tool.transform_keys(&:to_sym) : tool
              unless t[:type].to_s == 'function'
                log.debug("[llm][translator][openai_request] action=skip_unsupported_tool type=#{t[:type]}")
                next
              end

              fn = t[:function]
              fn = fn.transform_keys(&:to_sym) if fn.respond_to?(:transform_keys)
              next unless fn.is_a?(Hash)

              {
                name:        fn[:name].to_s,
                description: fn[:description].to_s,
                parameters:  fn[:parameters] || {}
              }
            end
          end
        end
      end
    end
  end
end
