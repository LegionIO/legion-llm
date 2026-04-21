# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Native
        module Chat
          extend Legion::Logging::Helper

          def self.registered(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
            log.debug('[llm][api][chat] registering POST /api/llm/chat')

            app.post '/api/llm/chat' do # rubocop:disable Metrics/BlockLength
              log.debug("[llm][api][chat] action=received params=#{params.keys}")
              require_llm!

              body = parse_request_body
              validate_required!(body, :message)

              message = body[:message]

              if defined?(Legion::MCP::TierRouter)
                log.debug('[llm][api][chat] action=tier_routing_check')
                tier_result = Legion::MCP::TierRouter.route(
                  intent:  message,
                  params:  body.except(:message, :model, :provider, :request_id),
                  context: {}
                )
                if tier_result[:tier]&.zero?
                  log.info("[llm][api][chat] action=tier0_response request_id=#{body[:request_id] || 'generated'} latency_ms=#{tier_result[:latency_ms]}")
                  halt json_response({
                                       response:           tier_result[:response],
                                       tier:               0,
                                       latency_ms:         tier_result[:latency_ms],
                                       pattern_confidence: tier_result[:pattern_confidence]
                                     })
                end
              end

              request_id = body[:request_id] || SecureRandom.uuid
              model      = body[:model]
              provider   = body[:provider]
              log.debug("[llm][api][chat] action=dispatch request_id=#{request_id} model=#{model || 'auto'} provider=#{provider || 'auto'}")

              if cache_available? && env['HTTP_X_LEGION_SYNC'] != 'true'
                log.debug("[llm][api][chat] action=async_dispatch request_id=#{request_id}")
                llm = Legion::LLM
                rc  = Legion::LLM::Cache::Response
                rc.init_request(request_id)

                Thread.new do
                  session  = llm.chat_direct(model: model, provider: provider)
                  response = session.ask(message)
                  rc.complete(
                    request_id,
                    response: response.content,
                    meta:     {
                      model:      session.model.to_s,
                      tokens_in:  response.respond_to?(:input_tokens) ? response.input_tokens : nil,
                      tokens_out: response.respond_to?(:output_tokens) ? response.output_tokens : nil
                    }
                  )
                  log.debug("[llm][api][chat] action=async_complete request_id=#{request_id}")
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: true, operation: 'llm.api.chat.async', request_id: request_id)
                  rc.fail_request(request_id, code: 'llm_error', message: e.message)
                end

                log.info("[llm][api][chat] action=queued request_id=#{request_id}")
                json_response({ request_id: request_id, poll_key: "llm:#{request_id}:status" },
                              status_code: 202)
              else
                log.debug("[llm][api][chat] action=sync_dispatch request_id=#{request_id}")
                result = Legion::LLM.chat(message: message, model: model, provider: provider,
                                          caller: { source: 'api', path: request.path })
                if result.is_a?(Legion::LLM::Inference::Response)
                  raw_msg  = result.message
                  content  = raw_msg.is_a?(Hash) ? (raw_msg[:content] || raw_msg['content']) : raw_msg.to_s
                  routing  = result.routing || {}
                  resolved_model = routing[:model] || routing['model']
                  tokens = result.tokens || {}
                  log.info("[llm][api][chat] action=completed request_id=#{request_id} model=#{resolved_model}")
                  json_response(
                    {
                      response: content,
                      meta:     {
                        model:      resolved_model.to_s,
                        tokens_in:  token_value(tokens, :input),
                        tokens_out: token_value(tokens, :output)
                      }
                    },
                    status_code: 201
                  )
                else
                  response = result
                  log.info("[llm][api][chat] action=completed request_id=#{request_id} result_class=#{response.class}")
                  json_response(
                    {
                      response: response.respond_to?(:content) ? response.content : response.to_s,
                      meta:     {
                        model:      response.respond_to?(:model_id) ? response.model_id.to_s : model.to_s,
                        tokens_in:  response.respond_to?(:input_tokens) ? response.input_tokens : nil,
                        tokens_out: response.respond_to?(:output_tokens) ? response.output_tokens : nil
                      }
                    },
                    status_code: 201
                  )
                end
              end
            end

            log.debug('[llm][api][chat] POST /api/llm/chat registered')
          end
        end
      end
    end
  end
end
