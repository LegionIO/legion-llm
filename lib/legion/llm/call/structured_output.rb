# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Call
      module StructuredOutput
        extend Legion::Logging::Helper

        SCHEMA_CAPABLE_MODELS = %w[gpt-4o gpt-4o-mini gpt-4-turbo claude-3-5-sonnet claude-4-sonnet claude-4-opus].freeze

        class << self
          def generate(messages:, schema:, model: nil, provider: nil, **)
            model ||= Legion::LLM.settings[:default_model]
            result = call_with_schema(messages, schema, model, provider: provider, **)

            parsed = Legion::JSON.load(result[:content])
            { data: parsed, raw: result[:content], model: result[:model], valid: true }
          rescue ::JSON::ParserError => e
            handle_parse_error(e, messages, schema, model, provider, result, **)
          end

          private

          def call_with_schema(messages, schema, model, provider: nil, **opts)
            if supports_response_format?(model)
              Legion::LLM::Inference.send(:chat_single,
                                          model: model, provider: provider, intent: nil, tier: nil,
                                          response_format: { type:        'json_schema',
                                                             json_schema: { name: 'response', schema: schema } },
                                          **opts.except(:attempt))
            else
              log.debug("StructuredOutput using prompt-based fallback for model=#{model}")
              instruction = "You MUST respond with valid JSON matching this schema:\n" \
                            "```json\n#{Legion::JSON.dump(schema)}\n```\n" \
                            'Respond with ONLY the JSON object, no other text.'
              augmented = [{ role: 'system', content: instruction }] + Array(messages)
              Legion::LLM::Inference.send(:chat_single,
                                          model: model, provider: provider, intent: nil, tier: nil,
                                          messages: augmented, **opts.except(:attempt))
            end
          end

          def handle_parse_error(error, messages, schema, model, provider, result, **opts)
            attempt = opts[:attempt] || 0
            log.warn("StructuredOutput JSON parse failure attempt=#{attempt} model=#{model}: #{error.message}")
            if retry_enabled? && attempt < max_retries
              retry_with_instruction(messages, schema, model, provider: provider, attempt: attempt + 1, **opts)
            else
              { data: nil, error: "JSON parse failed: #{error.message}", raw: result&.dig(:content), valid: false }
            end
          end

          def retry_with_instruction(messages, schema, model, provider: nil, **opts)
            instruction = "Your previous response was not valid JSON. Respond with ONLY a valid JSON object matching this schema:\n#{Legion::JSON.dump(schema)}"
            augmented = Array(messages) + [{ role: 'user', content: instruction }]
            result = Legion::LLM::Inference.send(:chat_single,
                                                 model: model, provider: provider, intent: nil, tier: nil,
                                                 messages: augmented, **opts.except(:attempt))

            parsed = Legion::JSON.load(result[:content])
            { data: parsed, raw: result[:content], model: result[:model], valid: true, retried: true }
          rescue StandardError => e
            handle_exception(e, level: :warn)
            { data: nil, error: e.message, valid: false }
          end

          def supports_response_format?(model)
            SCHEMA_CAPABLE_MODELS.any? { |m| model.to_s.include?(m) }
          end

          def retry_enabled?
            Legion::Settings.dig(:llm, :structured_output, :retry_on_parse_failure) != false
          end

          def max_retries
            Legion::Settings.dig(:llm, :structured_output, :max_retries) || 2
          end
        end
      end
    end
  end
end
