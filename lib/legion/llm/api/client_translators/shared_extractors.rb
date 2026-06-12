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

          def serialize_args(args)
            return args.to_s if args.is_a?(String)

            Legion::JSON.dump(args || {})
          rescue StandardError
            args.to_s
          end
        end
      end
    end
  end
end
