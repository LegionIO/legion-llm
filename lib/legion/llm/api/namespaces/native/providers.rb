# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/logging/helper'
require 'legion/llm/call/registry'
require 'legion/llm/api/native/providers'

module Legion
  module LLM
    module API
      module Namespaces
        module Native
          module Providers
            extend Legion::Logging::Helper

            def self.registered(ns_context)
              log.debug('[llm][api][namespaces][providers] registering routes')

              ns_context.get '' do
                log.debug('[llm][api][namespaces][providers] action=list_providers')
                require_llm!

                snapshot = Legion::LLM::Inventory.snapshot
                provider_list = Legion::LLM::API::Native::Providers.instances(snapshot: snapshot)

                summary = {
                  total:           provider_list.size,
                  native:          provider_list.count { |p| p[:native] },
                  routing_enabled: provider_list.any?
                }

                log.debug("[llm][api][namespaces][providers] action=listed count=#{provider_list.size}")
                json_response({ providers: provider_list, summary: summary })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.providers.list')
                json_error('provider_error', e.message, status_code: 500)
              end

              ns_context.get '/:name' do
                provider_name = params[:name].to_s
                log.debug("[llm][api][namespaces][providers] action=get_provider name=#{provider_name}")
                require_llm!

                snapshot = Legion::LLM::Inventory.snapshot
                family = Legion::LLM::API::Native::Providers.instances(snapshot: snapshot, provider: provider_name)

                unless family.any?
                  log.debug("[llm][api][namespaces][providers] action=not_found name=#{provider_name}")
                  halt json_error('provider_not_found', "Provider '#{provider_name}' not found", status_code: 404)
                end

                provider_list = family

                log.debug("[llm][api][namespaces][providers] action=found name=#{provider_name} instances=#{provider_list.size}")
                json_response({ provider: provider_name, instances: provider_list })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.providers.get')
                json_error('provider_error', e.message, status_code: 500)
              end

              log.debug('[llm][api][namespaces][providers] routes registered')
            end
          end
        end
      end
    end
  end
end
