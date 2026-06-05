# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'
require 'legion/llm/inference/request'
require 'legion/llm/inference/executor'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Moderations
            extend Legion::Logging::Helper

            MODERATION_CATEGORIES = %w[
              hate
              hate/threatening
              harassment
              harassment/threatening
              self-harm
              self-harm/intent
              self-harm/instructions
              sexual
              sexual/minors
              violence
              violence/graphic
            ].freeze

            DEFAULT_SCORES = MODERATION_CATEGORIES.to_h { |cat| [cat.to_sym, 0.0001] }.freeze
            DEFAULT_FLAGS  = MODERATION_CATEGORIES.to_h { |cat| [cat.to_sym, false] }.freeze

            MAX_MODERATION_INPUTS = 32

            def self.registered(app)
              log.debug('[llm][api][namespaces][openai][moderations] registering routes')

              app.post '/v1/moderations' do
                require_llm!

                capable = Legion::LLM::Call::Registry.providers.any? do |_name, entry|
                  caps = entry&.dig(:capabilities) || []
                  caps.include?(:moderation) || caps.include?(:chat)
                end
                unless capable
                  return openai_error('No provider with moderation or chat capability is configured',
                                      type: 'not_implemented_error', code: 'capability_unavailable', status_code: 501)
                end

                body = parse_request_body

                raw_input = body[:input]

                if raw_input.nil? || (raw_input.respond_to?(:empty?) && raw_input.empty?)
                  return openai_error('input is required and must be a non-empty string or array',
                                      type: 'invalid_request_error', status_code: 400)
                end

                inputs = raw_input.is_a?(Array) ? raw_input : [raw_input.to_s]

                if inputs.size > MAX_MODERATION_INPUTS
                  return openai_error("input array exceeds maximum size of #{MAX_MODERATION_INPUTS}",
                                      type: 'invalid_request_error', code: 'too_many_inputs', status_code: 400)
                end

                model = (body[:model] || 'text-moderation-latest').to_s

                log.info("[llm][api][namespaces][openai][moderations] action=accepted inputs=#{inputs.size} model=#{model}")

                effective_caller = build_server_caller(source: 'openai_moderations', path: request.path, env: env)

                results = inputs.map do |text|
                  Legion::LLM::API::Namespaces::OpenAI::Moderations.evaluate_single(
                    text.to_s, model: model, caller: effective_caller
                  )
                end

                response_body = {
                  id:      "modr-#{SecureRandom.hex(16)}",
                  model:   model,
                  results: results
                }

                log.info("[llm][api][namespaces][openai][moderations] action=complete inputs=#{inputs.size} flagged=#{results.count { |r| r[:flagged] }}")
                content_type :json
                status 200
                Legion::JSON.dump(response_body)
              rescue Legion::LLM::AuthError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.moderations.auth')
                openai_error(e.message, type: 'authentication_error', status_code: 401)
              rescue Legion::LLM::RateLimitError => e
                handle_exception(e, level: :warn, handled: true, operation: 'llm.api.namespaces.openai.moderations.rate_limit')
                openai_error(e.message, type: 'rate_limit_error', code: 'rate_limit_exceeded', status_code: 429)
              rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.moderations.provider')
                openai_error(e.message, type: 'server_error', status_code: 502)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.moderations')
                openai_error(e.message, type: 'server_error', status_code: 500)
              end
              log.debug('[llm][api][namespaces][openai][moderations] routes registered')
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.moderations.register')
            end

            # @api private — Evaluates a single text input through the Inference pipeline.
            def self.evaluate_single(text, model:, caller:)
              request_id = "modr_req_#{SecureRandom.hex(12)}"

              inference_request = Legion::LLM::Inference::Request.build(
                id:       request_id,
                system:   build_moderation_prompt,
                messages: [{ role: 'user', content: "<content_to_evaluate>#{text}</content_to_evaluate>" }],
                routing:  { model: model },
                tokens:   { max: 512 },
                caller:   caller,
                stream:   false,
                cache:    { strategy: :default, cacheable: true }
              )

              pipeline_response = Legion::LLM::Inference::Executor.new(inference_request).call

              response_text = extract_response_text(pipeline_response)
              log.debug("[llm][api][namespaces][openai][moderations] action=evaluated request_id=#{request_id} text_length=#{text.length}")

              parse_moderation_response(response_text)
              # NOTE: LLM errors (ProviderDown, timeout, AuthError, RateLimitError, etc.) are intentionally
              # NOT rescued here — they propagate up to the route block which returns 503/502 instead of
              # silently returning "safe" defaults for content that was never actually assessed.
            rescue Legion::LLM::LLMError
              raise # re-raise all LLM errors so the route block handles them with the correct HTTP status
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'llm.api.namespaces.openai.moderations.evaluate_single',
                              request_id: request_id)
              { flagged: false, categories: DEFAULT_FLAGS.dup, category_scores: DEFAULT_SCORES.dup }
            end

            def self.build_moderation_prompt
              category_list = MODERATION_CATEGORIES.map { |c| "- #{c}" }.join("\n")

              <<~PROMPT.strip
                You are a content safety classifier. Evaluate ONLY the content enclosed in <content_to_evaluate> tags against the following harm categories. Do not evaluate any text outside those tags.

                Categories:
                #{category_list}

                Response format (use EXACTLY this structure):
                MODERATION_RESULT: safe|flagged. Categories: hate=true|false(score), hate/threatening=true|false(score), harassment=true|false(score), harassment/threatening=true|false(score), self-harm=true|false(score), self-harm/intent=true|false(score), self-harm/instructions=true|false(score), sexual=true|false(score), sexual/minors=true|false(score), violence=true|false(score), violence/graphic=true|false(score)

                Rules:
                - Evaluate ONLY the content inside <content_to_evaluate>...</content_to_evaluate> tags
                - Set the overall result to "flagged" if ANY category is true, otherwise "safe"
                - Scores are floats between 0.0 and 1.0 representing confidence
                - A category is true if the score is >= 0.5
                - Be conservative: only flag content that clearly violates a category
              PROMPT
            end

            def self.parse_moderation_response(text)
              return safe_defaults unless text.to_s.include?('MODERATION_RESULT')

              flagged = text.match?(/MODERATION_RESULT:\s*flagged/i)
              categories = DEFAULT_FLAGS.dup
              scores     = DEFAULT_SCORES.dup

              MODERATION_CATEGORIES.each do |cat|
                escaped = Regexp.escape(cat)
                match = text.match(/#{escaped}=(true|false)\(([0-9.]+)\)/i)
                next unless match

                flag  = match[1].casecmp('true').zero?
                score = match[2].to_f.clamp(0.0, 1.0)
                categories[cat.to_sym] = flag
                scores[cat.to_sym]     = score
              end

              # If model says "safe" but individual categories are flagged, categories are authoritative
              flagged = categories.any? { |_, v| v } if text.match?(/MODERATION_RESULT:\s*safe/i) && categories.any? { |_, v| v }

              { flagged: flagged, categories: categories, category_scores: scores }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'llm.api.namespaces.openai.moderations.parse_response')
              safe_defaults
            end

            def self.safe_defaults
              { flagged: false, categories: DEFAULT_FLAGS.dup, category_scores: DEFAULT_SCORES.dup }
            end

            def self.extract_response_text(pipeline_response)
              msg = pipeline_response.message
              return '' if msg.nil?

              content = msg.is_a?(Hash) ? (msg[:content] || msg['content']) : msg.to_s
              if content.is_a?(Array)
                content.filter_map { |b| b.is_a?(Hash) ? (b[:text] || b['text']) : b.to_s }.join
              else
                content.to_s
              end
            end
          end
        end
      end
    end
  end
end
