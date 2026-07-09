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
            model ||= Legion::Settings[:llm][:default_model]
            result = call_with_schema(messages, schema, model, provider: provider, **)
            log.info "[llm][structured_output] model=#{model} provider=#{provider} valid=true"

            content = strip_markdown_fences(result.respond_to?(:content) ? result.content : result[:content])
            raw_model = result.respond_to?(:model_id) ? result.model_id : result[:model]

            parsed = Legion::JSON.load(content)
            { data: parsed, raw: content, model: raw_model, valid: true }
          rescue Legion::JSON::ParseError => e
            log.warn "[llm][structured_output] model=#{model} provider=#{provider} parse_error=#{e.message}"
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
              user_content = extract_user_content(messages, instruction)
              Legion::LLM::Inference.send(:chat_single,
                                          model: model, provider: provider, intent: nil, tier: nil,
                                          message: user_content, **opts.except(:attempt))
            end
          end

          def handle_parse_error(error, messages, schema, model, provider, result, **opts)
            attempt = opts[:attempt] || 0
            log.warn("StructuredOutput JSON parse failure attempt=#{attempt} model=#{model}: #{error.message}")
            if retry_enabled? && attempt < max_retries
              retry_with_instruction(messages, schema, model, provider: provider, attempt: attempt + 1, **opts)
            else
              raw = strip_markdown_fences(result.respond_to?(:content) ? result&.content : result&.dig(:content))
              { data: nil, error: "JSON parse failed: #{error.message}", raw: raw, valid: false }
            end
          end

          def retry_with_instruction(messages, schema, model, provider: nil, **opts)
            instruction = "Your previous response was not valid JSON. Respond with ONLY a valid JSON object matching this schema:\n#{Legion::JSON.dump(schema)}"
            user_content = extract_user_content(messages, instruction)
            route = alternate_retry_route(model, provider)
            retry_model = route[:model] || model
            retry_provider = route[:provider] || provider
            result = Legion::LLM::Inference.send(:chat_single,
                                                 model: retry_model, provider: retry_provider, intent: nil, tier: nil,
                                                 message: user_content, **opts.except(:attempt))

            retry_content = strip_markdown_fences(result.respond_to?(:content) ? result.content : result[:content])
            retry_model = result.respond_to?(:model_id) ? result.model_id : result[:model]

            parsed = Legion::JSON.load(retry_content)
            { data: parsed, raw: retry_content, model: retry_model, valid: true, retried: true, retry_route: route }
          rescue StandardError => e
            handle_exception(e, level: :warn)
            { data: nil, error: e.message, valid: false }
          end

          def alternate_retry_route(model, provider)
            return {} unless defined?(Legion::LLM::Router) && Legion::LLM::Router.respond_to?(:resolve_chain)

            chain = Legion::LLM::Router.resolve_chain(intent: { operation: :structured_output }, max_escalations: max_retries + 1)
            route = Array(chain).find do |candidate|
              candidate_model = route_value(candidate, :model)
              candidate_provider = route_value(candidate, :provider)
              next false if candidate_model.nil? && candidate_provider.nil?

              candidate_model.to_s != model.to_s || candidate_provider.to_s != provider.to_s
            end
            return {} unless route

            { model: route_value(route, :model), provider: route_value(route, :provider) }.compact
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.structured_output.alternate_retry_route')
            {}
          end

          def route_value(route, key)
            return route.public_send(key) if route.respond_to?(key)
            return route[key] if route.respond_to?(:key?) && route.key?(key)

            string_key = key.to_s
            route[string_key] if route.respond_to?(:key?) && route.key?(string_key)
          end

          def extract_user_content(messages, instruction)
            parts = [instruction]
            Array(messages).each do |msg|
              content = msg[:content] || msg['content']
              parts << content.to_s unless content.to_s.empty?
            end
            parts.join("\n\n")
          end

          def strip_markdown_fences(text)
            return text unless text.is_a?(String)

            stripped = text.strip
            return stripped unless stripped.start_with?('```')

            stripped
              .sub(/\A`{3,}[[:space:]]*(?:json)?[[:space:]]*\n?/i, '')
              .sub(/\n?[[:space:]]*`{3,}\z/, '')
              .strip
          end

          def supports_response_format?(model)
            # rubocop:disable Style/ArrayIntersect -- substring check (each model
            # fragment `include?`d in the model name), NOT array intersection.
            # `intersect?` raises TypeError on the String arg.
            SCHEMA_CAPABLE_MODELS.any? { |m| model.to_s.include?(m) }
            # rubocop:enable Style/ArrayIntersect
          end

          def retry_enabled?
            Legion::Settings.dig(:llm, :structured_output, :retry_on_parse_failure) != false
          end

          def max_retries
            Legion::Settings[:llm][:structured_output][:max_retries]
          end
        end
      end
    end
  end
end
