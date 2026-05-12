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
              raw_offerings = Legion::LLM::Inventory.offerings(filters)
              grouped = Legion::LLM::API::Native::Offerings.group_offerings(raw_offerings)

              json_response({
                              offerings: grouped,
                              summary:   Legion::LLM::API::Native::Offerings.summary(raw_offerings)
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

          def self.group_offerings(offerings)
            grouped = {}

            offerings.each do |offering|
              tier = (offering[:tier] || :unknown).to_s
              provider = (offering[:provider_family] || :unknown).to_s
              instance = (offering[:instance_id] || offering[:provider_instance] || :default).to_s

              grouped[tier] ||= {}
              grouped[tier][provider] ||= {}
              grouped[tier][provider][instance] ||= []
              grouped[tier][provider][instance] << compact_offering(offering)
            end

            grouped
          end

          def self.compact_offering(offering)
            {
              id:           offering[:offering_id] || offering[:id],
              model:        offering[:model].to_s,
              type:         offering[:type].to_s,
              model_family: offering[:model_family]&.to_s,
              capabilities: Array(offering[:capabilities]).map(&:to_s),
              limits:       offering[:limits] || {},
              enabled:      offering[:enabled] != false,
              cost:         offering[:cost] || {},
              health:       offering[:health] || {}
            }.compact
          end

          def self.summary(offerings)
            {
              total:     offerings.size,
              tiers:     offerings.map { |o| (o[:tier] || :unknown).to_s }.uniq.size,
              providers: offerings.map { |o| (o[:provider_family] || :unknown).to_s }.uniq.size,
              instances: offerings.map { |o| (o[:instance_id] || :default).to_s }.uniq.size,
              models:    offerings.map { |o| o[:model] }.uniq.size
            }
          end
        end
      end
    end
  end
end
