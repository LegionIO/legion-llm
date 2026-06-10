# frozen_string_literal: true

require 'securerandom'
require 'concurrent'
require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Namespaces
        module Native
          module Chat
            extend Legion::Logging::Helper

            ASYNC_POOL = Concurrent::FixedThreadPool.new(
              [4, (Concurrent.processor_count / 2)].max,
              fallback_policy: :caller_runs
            )

            # Ensure the thread pool is shut down cleanly when the process exits.
            # CRITICAL: Without this, Ruby will leak ASYNC_POOL threads on shutdown.
            at_exit do
              ASYNC_POOL.shutdown
              ASYNC_POOL.wait_for_termination(5)
            end

            def self.registered(ns_context)
              log.debug('[llm][api][namespaces][chat] registering routes')

              ns_context.post '' do
                log.debug("[llm][api][namespaces][chat] action=received params=#{params.keys}")
                require_llm!
                request_started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

                body = parse_request_body
                validate_required!(body, :message)

                message    = body[:message]
                request_id = body[:request_id] || SecureRandom.uuid
                model      = body[:model]
                provider   = body[:provider]

                log.debug("[llm][api][namespaces][chat] action=dispatch request_id=#{request_id} model=#{model || 'auto'}")

                cache_active = defined?(Legion::LLM::Cache::Response) &&
                               Legion::LLM::Cache::Response.respond_to?(:init_request) &&
                               env['HTTP_X_LEGION_SYNC'] != 'true'

                if cache_active
                  log.debug("[llm][api][namespaces][chat] action=async_dispatch request_id=#{request_id}")
                  Legion::LLM::Cache::Response.init_request(request_id)
                  llm = Legion::LLM
                  rc  = Legion::LLM::Cache::Response

                  begin
                    ASYNC_POOL.post do
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
                      Legion::LLM::Audit.emit_prompt(
                        request_id: request_id,
                        caller:     { requested_by: { identity: 'api:chat:async', type: :external } },
                        routing:    { model: session.model.to_s, provider: provider },
                        tokens:     { input_tokens:  response.respond_to?(:input_tokens) ? response.input_tokens : 0,
                                      output_tokens: response.respond_to?(:output_tokens) ? response.output_tokens : 0 },
                        timestamp:  Time.now
                      )
                      log.debug("[llm][api][namespaces][chat] action=async_complete request_id=#{request_id}")
                    rescue StandardError => e
                      handle_exception(e, level: :error, handled: true, operation: 'llm.api.chat.async', request_id: request_id)
                      rc.fail_request(request_id, code: 'llm_error', message: e.message)
                    end
                  rescue Concurrent::RejectedExecutionError
                    log.warn("[llm][api][namespaces][chat] action=async_pool_saturated request_id=#{request_id}")
                    halt json_error('queue_full', 'Chat queue is currently full. Please retry.', status_code: 503)
                  end

                  log.info("[llm][api][namespaces][chat] action=queued request_id=#{request_id}")
                  json_response({ request_id: request_id, poll_key: "llm:#{request_id}:status" }, status_code: 202)
                else
                  log.debug("[llm][api][namespaces][chat] action=sync_dispatch request_id=#{request_id}")
                  result = Legion::LLM.chat(
                    message:  message,
                    model:    model,
                    provider: provider,
                    caller:   build_server_caller(source: 'api', path: request.path, env: env)
                  )

                  if result.is_a?(Legion::LLM::Inference::Response)
                    raw_msg         = result.message
                    content         = raw_msg.is_a?(Hash) ? (raw_msg[:content] || raw_msg['content']) : raw_msg.to_s
                    routing         = result.routing || {}
                    resolved_model  = routing[:model] || routing['model']
                    tokens          = result.tokens || {}
                    log_api_completion_summary(
                      namespace:         'namespaces][chat',
                      request_id:        request_id,
                      pipeline_response: result,
                      stream:            false,
                      started_at:        request_started_at,
                      tool_calls:        extract_tool_calls(result),
                      stop_reason:       api_stop_reason(result)
                    )
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
                    log.info("[llm][api][namespaces][chat] action=completed request_id=#{request_id} result_class=#{response.class}")
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

              log.debug('[llm][api][namespaces][chat] routes registered')
            end
          end
        end
      end
    end
  end
end
