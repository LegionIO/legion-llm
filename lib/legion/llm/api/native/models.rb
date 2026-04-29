# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Native
        module Models
          extend Legion::Logging::Helper

          def self.registered(app)
            log.debug('[llm][api][models] registering model inventory routes')

            app.get '/api/llm/models' do
              log.debug('[llm][api][models] action=list_models')
              require_llm!

              filters = Legion::LLM::API::Native::Models.request_filters(params)
              offerings = Legion::LLM::Inventory.offerings(filters)

              json_response({
                              models:    Legion::LLM::API::Native::Models.model_summaries(offerings),
                              offerings: offerings,
                              summary:   Legion::LLM::API::Native::Models.summary(offerings)
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.models.list')
              json_error('model_inventory_error', e.message, status_code: 500)
            end

            app.get '/api/llm/models/:id' do
              model_id = params[:id]
              log.debug("[llm][api][models] action=get_model id=#{model_id}")
              require_llm!

              offerings = Legion::LLM::Inventory.offerings(model: model_id)
              halt json_error('model_not_found', "Model '#{model_id}' not found", status_code: 404) unless offerings.any?

              json_response({
                              model:     Legion::LLM::API::Native::Models.summarize_model(model_id, offerings),
                              offerings: offerings
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.models.get')
              json_error('model_inventory_error', e.message, status_code: 500)
            end

            app.get '/api/llm/providers/:name/models' do
              provider = params[:name]
              log.debug("[llm][api][models] action=list_provider_models provider=#{provider}")
              require_llm!

              filters = Legion::LLM::API::Native::Models.request_filters(params).merge(provider: provider)
              offerings = Legion::LLM::Inventory.offerings(filters)

              json_response({
                              provider:  provider,
                              models:    Legion::LLM::API::Native::Models.model_summaries(offerings),
                              offerings: offerings,
                              summary:   Legion::LLM::API::Native::Models.summary(offerings)
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.models.provider')
              json_error('model_inventory_error', e.message, status_code: 500)
            end

            log.debug('[llm][api][models] model inventory routes registered')
          end

          def self.request_filters(params)
            {
              provider:     params[:provider],
              instance_id:  params[:instance_id] || params[:instance],
              type:         params[:type] || params[:purpose],
              model:        params[:model],
              offering_id:  params[:offering_id],
              model_family: params[:model_family],
              capability:   params[:capability]
            }
          end

          def self.model_summaries(offerings)
            summaries = offerings.group_by { |offering| offering[:model] }.map do |model, rows|
              summarize_model(model, rows)
            end
            summaries.sort_by { |model| model[:id] }
          end

          def self.summarize_model(model, offerings)
            {
              id:             model.to_s,
              types:          offerings.map { |offering| offering[:type].to_s }.uniq.sort,
              providers:      offerings.map { |offering| offering[:provider_family] }.uniq.sort,
              model_families: offerings.filter_map { |offering| offering[:model_family] }.uniq.sort,
              offering_ids:   offerings.filter_map { |offering| offering[:offering_id] }.uniq.sort,
              instances:      offerings.map { |offering| offering[:instance_id] }.uniq.sort,
              capabilities:   offerings.flat_map { |offering| offering[:capabilities] }.uniq.sort,
              max_context:    offerings.filter_map { |offering| offering.dig(:limits, :context_window) }.max,
              enabled:        offerings.any? { |offering| offering[:enabled] != false }
            }
          end

          def self.summary(offerings)
            {
              total_offerings: offerings.size,
              models:          offerings.map { |offering| offering[:model] }.uniq.size,
              providers:       offerings.map { |offering| offering[:provider_family] }.uniq.size,
              by_type:         offerings.group_by { |offering| offering[:type].to_s }
                                        .transform_values(&:size)
            }
          end
        end
      end
    end
  end
end
