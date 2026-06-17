# frozen_string_literal: true

module Legion
  module LLM
    module API
      module ClientTranslators
        # Token-count and thinking-text extraction shared by all client translators.
        # Single source of truth — replaces the 3-way duplicate that lived in
        # AnthropicMessages, OpenAIChat, and OpenAIResponses (P6 dedup).
        module SharedExtractors
          def token_value(tokens, *keys)
            return 0 if tokens.nil?

            keys.each do |key|
              value = if tokens.is_a?(Hash)
                        tokens[key] || tokens[key.to_s]
                      elsif tokens.respond_to?(key)
                        tokens.public_send(key)
                      end
              return value.to_i unless value.nil?
            end
            0
          end

          def extract_thinking_text(value)
            return '' if value.nil?
            return value.to_s if value.is_a?(String)

            if value.is_a?(Hash)
              normalized = value.transform_keys { |k| k.respond_to?(:to_sym) ? k.to_sym : k }
              text = normalized[:content] || normalized[:text] || normalized[:thinking] || normalized[:reasoning]
              return text.to_s if text
            end

            return value.content.to_s if value.respond_to?(:content) && value.content
            return value.text.to_s if value.respond_to?(:text) && value.text

            value.to_s
          end

          def extract_content_text(value)
            return '' if value.nil?
            return value if value.is_a?(String)

            if value.is_a?(Array)
              return value.filter_map do |part|
                text = extract_content_text(part)
                text.empty? ? nil : text
              end.join
            end

            if value.is_a?(Hash)
              normalized = value.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
              content = normalized[:content]
              return extract_content_text(content) unless content.nil?

              return '' unless text_content_type?(normalized[:type])

              text = normalized[:text] || normalized[:output_text] || normalized[:value]
              return extract_content_text(text) unless text.nil?

              return ''
            end

            if value.respond_to?(:text)
              type = value.respond_to?(:type) ? value.type : nil
              return '' unless text_content_type?(type)

              return value.text.to_s
            end

            return extract_content_text(value.content) if value.respond_to?(:content)

            value.to_s
          end

          def text_content_type?(type)
            type_string = type.to_s
            type_string.empty? || %w[text output_text input_text].include?(type_string)
          end

          def legion_routing_from_env(env)
            {
              model:    env['HTTP_X_LEGION_MODEL'],
              provider: env['HTTP_X_LEGION_PROVIDER'],
              instance: env['HTTP_X_LEGION_INSTANCE']
            }.compact
          end

          def legion_routing_explicit_from_env(env)
            flags = {
              model:    env.key?('HTTP_X_LEGION_MODEL'),
              provider: env.key?('HTTP_X_LEGION_PROVIDER'),
              instance: env.key?('HTTP_X_LEGION_INSTANCE'),
              tier:     env.key?('HTTP_X_LEGION_TIER')
            }.select { |_, value| value }
            flags.empty? ? nil : flags
          end

          # Tool-call argument coercion is FORMAT-SPECIFIC. The two client
          # surfaces have incompatible wire requirements:
          #
          #   - Anthropic /v1/messages tool_use.input  MUST be an Object/Hash.
          #     (`{"type":"tool_use","input":{"command":"ls"}}` — never a string.)
          #   - OpenAI   function_call.arguments       MUST be a JSON String.
          #     (`{"name":"bash","arguments":"{\"command\":\"ls\"}"}` — never an object.)
          #
          # A single uniform helper ("everything is a string") was the bug
          # behind the claude/vllm multi-turn regression where `tool_use.input`
          # surfaced as a JSON string (or worse — a coerced numeric like
          # `1.01` from a degraded model output). Use the explicit per-format
          # helper at the call site; never rebalance by pushing one format's
          # shape onto the other.

          # Coerce raw tool arguments into the OpenAI wire shape: a JSON
          # string. Non-string inputs are JSON-dumped; nil becomes "{}";
          # malformed values are stringified as a last resort so the wire
          # never carries a Ruby object.
          def args_as_json_string(args)
            return args if args.is_a?(String)

            Legion::JSON.dump(args || {})
          rescue StandardError
            args.to_s
          end

          # Coerce raw tool arguments into the Anthropic wire shape: a Hash.
          # Strings are parsed as JSON when possible; non-Hash literals
          # (numbers, arrays from degraded model output) collapse to `{}`
          # rather than violating the contract.
          def args_as_object(args)
            return args if args.is_a?(Hash)
            return {} if args.nil?

            if args.is_a?(String)
              return {} if args.empty?

              parsed = Legion::JSON.load(args)
              return parsed if parsed.is_a?(Hash)
            end

            {}
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end
