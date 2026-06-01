# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Native
        module Models
          extend Legion::Logging::Helper

          AUTO_ROUTING_MODEL_ID = 'legionio'
          AUTO_ROUTING_MODEL_DISPLAY = 'LegionIO'
          AUTO_ROUTING_OFFERING_ID = 'legionio:auto:inference:legionio'
          AUTO_ROUTING_CAPABILITIES = %w[auto_routing chat completion json_schema tools].freeze

          def self.registered(app)
            log.debug('[llm][api][models] registering model inventory routes')

            app.get '/api/llm/models' do
              log.debug('[llm][api][models] action=list_models')
              require_llm!

              filters = Legion::LLM::API::Native::Models.request_filters(params)
              offerings = Legion::LLM::Inventory.offerings(filters)
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

            app.get '/api/llm/models/:id' do
              model_id = params[:id]
              log.debug("[llm][api][models] action=get_model id=#{model_id}")
              require_llm!

              filters = { model: model_id }
              offerings = Legion::LLM::Inventory.offerings(filters)
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
            summaries.sort_by { |model| [auto_routing_model?(model[:id]) ? 0 : 1, model[:id]] }
          end

          def self.summarize_model(model, offerings)
            summary = {
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
            if auto_routing_model?(model)
              summary[:display_name] = AUTO_ROUTING_MODEL_DISPLAY
              summary[:auto_route] = true
              summary[:default] = true
            end
            summary
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

          def self.with_auto_routing_offering(offerings, filters = {})
            return offerings unless auto_routing_offering_matches?(filters)
            return offerings if offerings.any? { |offering| auto_routing_model?(offering[:model]) }

            [auto_routing_offering, *offerings]
          end

          def self.auto_routing_offering
            ctx = Legion::LLM::Settings.value(:context_window, default: 262_144)
            max_out = Legion::LLM::Settings.value(:max_output_tokens, default: 16_384)
            {
              id:                    AUTO_ROUTING_OFFERING_ID,
              offering_id:           AUTO_ROUTING_OFFERING_ID,
              model:                 AUTO_ROUTING_MODEL_ID,
              display_name:          AUTO_ROUTING_MODEL_DISPLAY,
              model_family:          'legionio',
              canonical_model_alias: AUTO_ROUTING_MODEL_ID,
              type:                  :inference,
              provider_family:       'legionio',
              provider_instance:     'auto',
              instance_id:           'auto',
              tier:                  :auto,
              transport:             :internal,
              enabled:               true,
              capabilities:          AUTO_ROUTING_CAPABILITIES,
              limits:                { context_window: ctx, max_output_tokens: max_out },
              health:                { circuit_state: 'available' },
              metadata:              { auto_route: true, placeholder: true, display_name: AUTO_ROUTING_MODEL_DISPLAY },
              routing_metadata:      { strategy: 'auto' },
              source:                'static'
            }
          end

          def self.auto_routing_offering_matches?(filters)
            normalized = request_filters(filters)
            type = normalized[:type]
            return false if type && !type.to_s.empty? && type.to_s != 'inference' && type.to_s != 'chat'

            provider = normalized[:provider]
            return false if provider && !provider.to_s.empty? && !%w[legionio auto].include?(provider.to_s.downcase)

            instance = normalized[:instance_id]
            return false if instance && !instance.to_s.empty? && !%w[auto legionio].include?(instance.to_s.downcase)

            model = normalized[:model] || normalized[:offering_id]
            return false if model && !model.to_s.empty? && !auto_routing_model?(model) && model.to_s != AUTO_ROUTING_OFFERING_ID

            family = normalized[:model_family]
            return false if family && !family.to_s.empty? && family.to_s.downcase != 'legionio'

            capability = normalized[:capability]
            return false if capability && !AUTO_ROUTING_CAPABILITIES.include?(capability.to_s)

            true
          end

          def self.auto_routing_model?(model)
            model.to_s.strip.downcase == AUTO_ROUTING_MODEL_ID
          end
        end
      end
    end
  end
end
