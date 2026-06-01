# frozen_string_literal: true

require 'time'
require 'legion/logging/helper'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/native/models'
require 'legion/llm/api/translators/openai_response'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          # Single namespace serving /v1/models for BOTH OpenAI and Anthropic clients.
          # Uses detect_client(env) to branch between formats.
          module Models
            extend Legion::Logging::Helper

            def self.registered(app)
              log.debug('[llm][api][namespaces][openai][models] registering routes')

              app.get '/v1/models' do
                require_llm!
                client = detect_client(env)
                log.debug("[llm][api][namespaces][openai][models] action=list client=#{client}")

                model_list = Models.build_openai_model_list
                log.debug("[llm][api][namespaces][openai][models] action=listed count=#{model_list.size}")

                content_type :json
                if client == :anthropic
                  anthropic_list = Models.to_anthropic_model_list(model_list)
                  Legion::JSON.dump({
                                      data:     anthropic_list,
                                      has_more: false,
                                      first_id: anthropic_list.first&.dig(:id),
                                      last_id:  anthropic_list.last&.dig(:id)
                                    })
                else
                  Legion::JSON.dump({ object: 'list', data: model_list })
                end
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.models.list')
                openai_error(e.message, type: 'server_error', status_code: 500)
              end

              app.get '/v1/models/:id' do
                require_llm!
                model_id = params[:id]
                client   = detect_client(env)
                log.debug("[llm][api][namespaces][openai][models] action=get id=#{model_id} client=#{client}")

                model_list = Models.build_openai_model_list
                found = model_list.find { |m| m[:id] == model_id }

                unless found
                  return openai_error("Model '#{model_id}' not found",
                                      type: 'invalid_request_error', code: 'model_not_found', status_code: 404)
                end

                content_type :json
                if client == :anthropic
                  Legion::JSON.dump(Models.openai_to_anthropic_model(found))
                else
                  Legion::JSON.dump(found)
                end
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.models.get')
                openai_error(e.message, type: 'server_error', status_code: 500)
              end

              app.delete '/v1/models/:id' do
                model_id = params[:id]
                log.debug("[llm][api][namespaces][openai][models] action=delete id=#{model_id}")
                content_type :json
                Legion::JSON.dump({ id: model_id, object: 'model', deleted: true })
              end

              log.debug('[llm][api][namespaces][openai][models] routes registered')
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.models.register')
            end

            def self.build_openai_model_list
              offerings = Legion::LLM::Inventory.offerings(type: :inference)
              offerings = Legion::LLM::API::Native::Models.with_auto_routing_offering(offerings, {})

              models = offerings.map do |offering|
                Legion::LLM::API::Translators::OpenAIResponse.format_model_object(
                  offering[:model],
                  owned_by: offering[:provider_family],
                  limits:   offering[:limits]
                )
              end
              seen = {}
              models.select { |m| seen[m[:id]] ? false : (seen[m[:id]] = true) }
            rescue StandardError => e
              log.warn("[llm][api][namespaces][openai][models] inventory_error=#{e.message}")
              []
            end

            def self.to_anthropic_model_list(openai_list)
              openai_list.map { |m| openai_to_anthropic_model(m) }
            end

            def self.openai_to_anthropic_model(openai_model)
              model = {
                type:         'model',
                id:           openai_model[:id],
                display_name: openai_model[:id],
                created_at:   Time.at(openai_model[:created] || Time.now.to_i).utc.strftime('%Y-%m-%dT%H:%M:%SZ')
              }
              model[:max_input_tokens] = openai_model[:context_window] if openai_model[:context_window]
              model[:max_tokens] = openai_model[:max_output_tokens] if openai_model[:max_output_tokens]
              model
            end
          end
        end
      end
    end
  end
end
