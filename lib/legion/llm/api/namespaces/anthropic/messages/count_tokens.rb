# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/extension'
require 'sinatra/namespace'
require 'legion/llm/token_estimation'

module Legion
  module LLM
    module API
      module Namespaces
        module Anthropic
          module Messages
            module CountTokens
              extend Sinatra::Extension
              extend Legion::Logging::Helper

              post '/count_tokens' do
                require_llm!
                body = parse_request_body

                missing = []
                missing << 'model' if body[:model].nil? || body[:model].to_s.empty?
                missing << 'messages' if body[:messages].nil? || !body[:messages].is_a?(Array) || body[:messages].empty?
                unless missing.empty?
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ type: 'error', error: { type: 'invalid_request_error', message: "missing required fields: #{missing.join(', ')}" } })
                end

                result = CountTokens.count_tokens_result(
                  messages: body[:messages],
                  model:    body[:model],
                  system:   body[:system],
                  tools:    body[:tools]
                )

                content_type :json
                status 200
                Legion::JSON.dump(result)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.count_tokens')
                anthropic_error('api_error', e.message, status_code: 500)
              end

              # SSOT v3 §20 (count_tokens row): choose the EXACT lane first, then use
              # that lane's callable tokenizer. `model` is a required, caller-supplied
              # value — never a default. When the SSOT registry publishes a
              # count_tokens lane for the requested model, the exact selected
              # callable's tokenizer is authoritative; otherwise (cold registry, no
              # count_tokens lane, or a callable without a tokenizer) fall back to the
              # provider-neutral TokenEstimation.
              def self.count_tokens_result(messages:, model:, system:, tools:)
                lane_count = count_tokens_via_selected_lane(messages: messages, model: model, system: system, tools: tools)
                return lane_count if lane_count

                Legion::LLM::TokenEstimation.estimate(messages: messages, model: model, system: system, tools: tools)
              end

              def self.count_tokens_via_selected_lane(messages:, model:, system:, tools:)
                snapshot = Legion::Extensions::Llm::Inventory::Registry.snapshot
                return nil unless snapshot.generation.positive?

                request = Legion::LLM::Inference::Request.build(
                  messages: messages,
                  system:   system,
                  routing:  { model: model },
                  tools:    tools || []
                )
                requirements = Legion::LLM::Router::RequestRequirements.build(
                  request:                request,
                  operation:              :count_tokens,
                  required_capabilities:  Legion::LLM::Router::RequiredCapabilities.call(request: request, operation: :count_tokens),
                  estimated_input_bound:  0,
                  required_output_tokens: 0
                )
                session = Legion::LLM::Inference::RoutingSession.new(request: request, requirements: requirements)
                attempt = session.next_attempt(snapshot: snapshot)
                return nil if attempt.is_a?(Legion::Extensions::Llm::Routing::Rejection)

                dispatch = Legion::LLM::Call::SelectionDispatch.call(
                  attempt_context: attempt,
                  arguments:       { messages: messages }
                )
                return nil unless dispatch.success?

                normalize_token_count(dispatch.value)
              rescue ::NoMethodError, ::ArgumentError, ::NotImplementedError
                # Programming errors are never swallowed — re-raise.
                raise
              rescue StandardError => e
                # Non-programming errors during lane selection/tokenizer dispatch fall
                # back to provider-neutral estimation.
                log.warn "[llm][ns][anthropic][count_tokens] action=lane_tokenizer_fallback error=#{e.class}: #{e.message}"
                nil
              end

              def self.normalize_token_count(value)
                return value if value.is_a?(Hash) && (value.key?(:input_tokens) || value.key?('input_tokens'))
                return { input_tokens: value } if value.is_a?(Integer)

                nil
              end
            end
          end
        end
      end
    end
  end
end
