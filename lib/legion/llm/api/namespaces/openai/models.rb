# frozen_string_literal: true

require 'time'
require 'legion/logging/helper'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/api/native/models'
require 'legion/llm/api/translators/openai_response'
require 'legion/llm/api/model_catalog'
require 'legion/llm/router/settings_state'

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

              # SSOT v3 Task 16: the maintained /v1/models tree is projected from a
              # single Registry snapshot + SettingsState generation captured per
              # request and rendered by ModelCatalog in the caller's dialect. The
              # snapshot-only catalog never calls the router — availability and lane
              # weight do not decide which models appear in the compat view.
              app.get '/v1/models' do
                require_llm!
                dialect = detect_client(env) == :anthropic ? :anthropic : :openai
                log.debug("[llm][api][namespaces][openai][models] action=list dialect=#{dialect}")

                snapshot          = Legion::Extensions::Llm::Inventory::Registry.snapshot
                settings_snapshot = Legion::LLM::Router::SettingsState.current
                entries = Legion::LLM::API::ModelCatalog.list(
                  snapshot: snapshot, settings_snapshot: settings_snapshot, dialect: dialect
                )
                log.debug("[llm][api][namespaces][openai][models] action=listed dialect=#{dialect} count=#{entries.size}")

                content_type :json
                if dialect == :anthropic
                  Legion::JSON.dump({
                                      data:     entries,
                                      has_more: false,
                                      first_id: entries.first&.dig(:id),
                                      last_id:  entries.last&.dig(:id)
                                    })
                else
                  Legion::JSON.dump({ object: 'list', data: entries })
                end
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.namespaces.openai.models.list')
                openai_error(e.message, type: 'server_error', status_code: 500)
              end

              Models.passthrough_model_ids.each do |passthrough_id|
                app.get "/v1/models/#{passthrough_id}" do
                  require_llm!
                  dialect = detect_client(env) == :anthropic ? :anthropic : :openai
                  log.debug("[llm][api][namespaces][openai][models] action=passthrough_model id=#{passthrough_id} dialect=#{dialect}")

                  snapshot          = Legion::Extensions::Llm::Inventory::Registry.snapshot
                  settings_snapshot = Legion::LLM::Router::SettingsState.current
                  found = Legion::LLM::API::ModelCatalog.fetch(
                    id: passthrough_id, snapshot: snapshot, settings_snapshot: settings_snapshot, dialect: dialect
                  )

                  unless found
                    return openai_error("Model '#{passthrough_id}' not found",
                                        type: 'invalid_request_error', code: 'model_not_found', status_code: 404)
                  end

                  content_type :json
                  Legion::JSON.dump(found)
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: true,
                                      operation: 'llm.api.namespaces.openai.models.passthrough')
                  openai_error(e.message, type: 'server_error', status_code: 500)
                end
              end

              app.get '/v1/models/:id' do
                require_llm!
                model_id = params[:id]
                dialect  = detect_client(env) == :anthropic ? :anthropic : :openai
                log.debug("[llm][api][namespaces][openai][models] action=get id=#{model_id} dialect=#{dialect}")

                snapshot          = Legion::Extensions::Llm::Inventory::Registry.snapshot
                settings_snapshot = Legion::LLM::Router::SettingsState.current
                found = Legion::LLM::API::ModelCatalog.fetch(
                  id: model_id, snapshot: snapshot, settings_snapshot: settings_snapshot, dialect: dialect
                )

                unless found
                  return openai_error("Model '#{model_id}' not found",
                                      type: 'invalid_request_error', code: 'model_not_found', status_code: 404)
                end

                content_type :json
                Legion::JSON.dump(found)
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

            def self.passthrough_model_ids
              Legion::Settings[:llm][:routing][:model_passthrough_ids]
            end

            def self.synthetic_model_for_auto_route(model_id)
              return nil unless Legion::LLM::Inventory.lanes.any?

              best_lane = Legion::LLM::Inventory.lanes.max_by { |l| l[:lane_weight].to_i }
              return nil unless best_lane

              Legion::LLM::API::Translators::OpenAIResponse.format_model_object(
                model_id,
                owned_by: 'legionio',
                limits:   best_lane[:limits]
              )
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
