# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Call
      # Structured (JSON-schema) generation. SSOT v3: every provider-backed turn
      # flows through the canonical Request -> Executor/RoutingSession path via
      # Prompt.dispatch. The json_schema response_format makes
      # Router::RequiredCapabilities derive the `structured_output` capability, so
      # the router selects a lane whose offering advertises it — there is no
      # hard-coded capable-model list, no model/provider default, and no dead
      # resolve_chain. Callers forward explicit provider/model or none.
      module StructuredOutput
        extend Legion::Logging::Helper

        class << self
          def generate(messages:, schema:, model: nil, provider: nil, **opts)
            result = run_structured_chat(messages: messages, schema: schema, model: model,
                                         provider: provider, **opts.except(:attempt))
            content = strip_markdown_fences(response_content(result))
            raw_model = response_model(result)

            parsed = Legion::JSON.load(content)
            log.info "[llm][structured_output] model=#{raw_model || model} provider=#{provider} valid=true"
            { data: parsed, raw: content, model: raw_model, valid: true }
          rescue Legion::JSON::ParseError => e
            log.warn "[llm][structured_output] model=#{model} provider=#{provider} parse_error=#{e.message}"
            handle_parse_error(e, messages, schema, model, provider, result, **opts)
          end

          private

          # Route the structured turn through the canonical pipeline. Prompt.dispatch
          # translates `schema:` into a json_schema response_format, so capability
          # derivation requires `structured_output` and the router selects an
          # eligible lane. Explicit provider/model are forwarded; nil means an empty
          # constraint (SSOT selection), never a default.
          def run_structured_chat(messages:, schema:, model:, provider:, **)
            Legion::LLM::Inference::Prompt.dispatch(
              Array(messages),
              model:    model,
              provider: provider,
              schema:   schema,
              **
            )
          end

          def handle_parse_error(error, messages, schema, model, provider, result, **opts)
            attempt = opts[:attempt] || 0
            log.warn("StructuredOutput JSON parse failure attempt=#{attempt} model=#{model}: #{error.message}")
            if retry_enabled? && attempt < max_retries
              retry_with_instruction(messages, schema, model, provider: provider, attempt: attempt + 1, **opts)
            else
              raw = strip_markdown_fences(response_content(result))
              { data: nil, error: "JSON parse failed: #{error.message}", raw: raw, valid: false }
            end
          end

          # Retry keeps the same explicit constraints (or none) and re-requests with a
          # corrective instruction appended. The router re-selects an eligible lane;
          # there is no separate alternate-route chain.
          def retry_with_instruction(messages, schema, model, provider: nil, **opts)
            instruction = 'Your previous response was not valid JSON. Respond with ONLY a valid JSON object ' \
                          "matching this schema:\n#{Legion::JSON.dump(schema)}"
            retry_messages = messages_with_instruction(messages, instruction)
            result = run_structured_chat(messages: retry_messages, schema: schema, model: model,
                                         provider: provider, **opts.except(:attempt))

            retry_content = strip_markdown_fences(response_content(result))
            retry_model = response_model(result)

            parsed = Legion::JSON.load(retry_content)
            { data: parsed, raw: retry_content, model: retry_model, valid: true, retried: true }
          rescue StandardError => e
            handle_exception(e, level: :warn)
            { data: nil, error: e.message, valid: false }
          end

          def messages_with_instruction(messages, instruction)
            Array(messages) + [{ role: 'user', content: instruction }]
          end

          # Extract text from a pipeline Inference::Response, a provider message, or
          # a hash-shaped result.
          def response_content(result)
            return nil if result.nil?

            if result.respond_to?(:message)
              msg = result.message
              return (msg.is_a?(Hash) ? (msg[:content] || msg['content']) : msg).to_s
            end
            return result.content if result.respond_to?(:content)
            return result[:content] || result['content'] if result.respond_to?(:[])

            nil
          end

          def response_model(result)
            return nil if result.nil?

            if result.respond_to?(:routing)
              routing = result.routing
              return routing[:model] || routing['model'] if routing.is_a?(Hash)
            end
            return result.model_id if result.respond_to?(:model_id)
            return result[:model] || result['model'] if result.respond_to?(:[])

            nil
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
