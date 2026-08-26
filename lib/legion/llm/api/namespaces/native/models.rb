# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/logging/helper'
require 'legion/llm/api/native/models'

module Legion
  module LLM
    module API
      module Namespaces
        module Native
          module Models
            extend Legion::Logging::Helper

            def self.registered(ns_context)
              log.debug('[llm][api][namespaces][models] registering routes')

              ns_context.get '' do
                log.debug('[llm][api][namespaces][models] action=list_models')
                require_llm!

                filters = Legion::LLM::API::Native::Models.request_filters(params)
                offerings = Legion::LLM::API::Native::Models.lane_entries(filters)
                offerings = Legion::LLM::API::Native::Models.with_auto_routing_offering(offerings, filters)

                json_response({
                                models:    Legion::LLM::API::Native::Models.model_summaries(offerings),
                                offerings: offerings,
                                summary:   Legion::LLM::API::Native::Models.summary(offerings)
                              })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.models.list')
                json_error('model_inventory_error', e.message, status_code: 500)
              end

              ns_context.get '/:id' do
                model_id = params[:id]
                log.debug("[llm][api][namespaces][models] action=get_model id=#{model_id}")
                require_llm!

                filters = { model: model_id }
                offerings = Legion::LLM::API::Native::Models.lane_entries(filters)
                offerings = Legion::LLM::API::Native::Models.with_auto_routing_offering(offerings, filters)
                halt json_error('model_not_found', "Model '#{model_id}' not found", status_code: 404) unless offerings.any?

                json_response({
                                model:     Legion::LLM::API::Native::Models.summarize_model(model_id, offerings),
                                offerings: offerings
                              })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.models.get')
                json_error('model_inventory_error', e.message, status_code: 500)
              end

              log.debug('[llm][api][namespaces][models] routes registered')
            end
          end
        end
      end
    end
  end
end
