# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Native
        module Offerings
          extend Legion::Logging::Helper

          def self.registered(app)
            log.debug('[llm][api][offerings] registering offering inventory routes')

            app.get '/api/llm/offerings' do
              log.debug('[llm][api][offerings] action=list_offerings')
              require_llm!

              filters = Legion::LLM::API::Native::Offerings.request_filters(params)
              offerings = Legion::LLM::Inventory.offerings(filters)

              json_response({
                              offerings: offerings,
                              summary:   Legion::LLM::API::Native::Offerings.summary(offerings, filters)
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.offerings.list')
              json_error('offering_inventory_error', e.message, status_code: 500)
            end

            app.get '/api/llm/offerings/:id' do
              offering_id = params[:id]
              log.debug("[llm][api][offerings] action=get_offering id=#{offering_id}")
              require_llm!

              offering = Legion::LLM::Inventory.offerings(offering_id: offering_id).first
              halt json_error('offering_not_found', "Offering '#{offering_id}' not found", status_code: 404) unless offering

              json_response({ offering: offering })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.offerings.get')
              json_error('offering_inventory_error', e.message, status_code: 500)
            end

            log.debug('[llm][api][offerings] offering inventory routes registered')
          end

          def self.request_filters(params)
            {
              provider:     params[:provider] || params[:provider_family],
              instance_id:  params[:instance_id] || params[:instance],
              type:         params[:operation] || params[:type] || params[:purpose],
              model:        params[:model],
              offering_id:  params[:offering_id],
              model_family: params[:family] || params[:model_family],
              capability:   params[:capability],
              tier:         params[:tier],
              healthy:      params[:healthy]
            }
          end

          def self.summary(offerings, filters)
            {
              total:     offerings.size,
              operation: filters[:type]&.to_s,
              models:    offerings.map { |offering| offering[:model] }.uniq.size,
              providers: offerings.map { |offering| offering[:provider_family] }.uniq.size,
              instances: offerings.map { |offering| offering[:instance_id] }.uniq.size
            }.compact
          end
        end
      end
    end
  end
end
