# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/logging/helper'
require 'legion/llm/api/native/offerings'

module Legion
  module LLM
    module API
      module Namespaces
        module Native
          module Offerings
            extend Legion::Logging::Helper

            def self.registered(ns_context)
              log.debug('[llm][api][namespaces][offerings] registering routes')

              ns_context.get '' do
                log.debug('[llm][api][namespaces][offerings] action=list_offerings')
                require_llm!

                filters = Legion::LLM::API::Native::Offerings.request_filters(params)
                raw_offerings = Legion::LLM::API::Native::Offerings.snapshot_offerings(filters)
                grouped = Legion::LLM::API::Native::Offerings.group_offerings(raw_offerings)

                json_response({
                                offerings: grouped,
                                summary:   Legion::LLM::API::Native::Offerings.summary(raw_offerings)
                              })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.offerings.list')
                json_error('offering_inventory_error', e.message, status_code: 500)
              end

              ns_context.get '/:id' do
                offering_id = params[:id]
                log.debug("[llm][api][namespaces][offerings] action=get_offering id=#{offering_id}")
                require_llm!

                offering = Legion::LLM::API::Native::Offerings.snapshot_offering(offering_id)
                halt json_error('offering_not_found', "Offering '#{offering_id}' not found", status_code: 404) unless offering

                json_response({ offering: offering })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.offerings.get')
                json_error('offering_inventory_error', e.message, status_code: 500)
              end

              log.debug('[llm][api][namespaces][offerings] routes registered')
            end
          end
        end
      end
    end
  end
end
