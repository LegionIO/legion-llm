# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Native
        module Providers
          extend Legion::Logging::Helper

          def self.registered(app) # rubocop:disable Metrics/MethodLength
            log.debug('[llm][api][providers] registering provider routes')

            app.get '/api/llm/providers' do
              log.debug('[llm][api][providers] action=list_providers')
              require_llm!

              providers_config = Legion::LLM.settings.fetch(:providers, {})
              provider_list = providers_config.filter_map do |name, config|
                next unless config.is_a?(Hash) && config[:enabled] != false

                health = if Legion::LLM::Router.routing_enabled?
                           tracker = Legion::LLM::Router.health_tracker
                           { circuit_state: tracker.circuit_state(name).to_s,
                             adjustment:    tracker.adjustment(name) }
                         else
                           { circuit_state: 'unknown' }
                         end

                {
                  name:          name.to_s,
                  enabled:       true,
                  default_model: config[:default_model],
                  health:        health,
                  native:        Legion::LLM::Call::Registry.registered?(name)
                }
              end

              summary = {
                total:           provider_list.size,
                native:          provider_list.count { |p| p[:native] },
                routing_enabled: Legion::LLM::Router.routing_enabled?
              }

              log.debug("[llm][api][providers] action=listed count=#{provider_list.size}")
              json_response({ providers: provider_list, summary: summary })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.providers.list')
              json_error('provider_error', e.message, status_code: 500)
            end

            app.get '/api/llm/providers/:name' do
              log.debug("[llm][api][providers] action=get_provider name=#{params[:name]}")
              require_llm!

              name = params[:name].to_sym
              config = Legion::LLM.settings.dig(:providers, name)

              unless config.is_a?(Hash) && config[:enabled] != false
                log.debug("[llm][api][providers] action=not_found name=#{params[:name]}")
                halt json_error('provider_not_found', "Provider '#{params[:name]}' not found or disabled", status_code: 404)
              end

              health = if Legion::LLM::Router.routing_enabled?
                         tracker = Legion::LLM::Router.health_tracker
                         { circuit_state: tracker.circuit_state(name).to_s,
                           adjustment:    tracker.adjustment(name) }
                       else
                         { circuit_state: 'unknown' }
                       end

              safe_config = config.except(:api_key, :secret_key, :bearer_token, :session_token)

              log.debug("[llm][api][providers] action=found name=#{params[:name]}")
              json_response({
                              name:          name.to_s,
                              enabled:       true,
                              default_model: config[:default_model],
                              health:        health,
                              native:        Legion::LLM::Call::Registry.registered?(name),
                              config:        safe_config
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.providers.get')
              json_error('provider_error', e.message, status_code: 500)
            end

            log.debug('[llm][api][providers] provider routes registered')
          end
        end
      end
    end
  end
end
