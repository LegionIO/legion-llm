# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Native
        module Providers
          extend Legion::Logging::Helper

          SECRET_KEYS = %w[
            api_key secret_key bearer_token session_token auth_token authorization password
          ].freeze

          def self.registered(app)
            log.debug('[llm][api][providers] registering provider routes')

            app.get '/api/llm/providers' do
              log.debug('[llm][api][providers] action=list_providers')
              require_llm!

              providers_config = Legion::LLM::API::Native::Providers.settings_value(:providers, {})
              provider_list = providers_config.filter_map do |name, config|
                next unless Legion::LLM::API::Native::Providers.enabled_provider_config?(config)

                provider_name = name.to_s

                {
                  name:          provider_name,
                  enabled:       true,
                  default_model: Legion::LLM::Settings.config_value(config, :default_model),
                  health:        Legion::LLM::API::Native::Providers.provider_health(provider_name),
                  instances:     Legion::LLM::Call::Registry.instances_for(provider_name.to_sym).map do |inst_id, _adapter|
                                   { id: inst_id.to_s }
                                 end,
                  native:        Legion::LLM::Call::Registry.registered?(provider_name.to_sym)
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

              provider_name = params[:name].to_s
              provider_config = Legion::LLM::API::Native::Providers.find_provider_config(provider_name)

              unless Legion::LLM::API::Native::Providers.enabled_provider_config?(provider_config)
                log.debug("[llm][api][providers] action=not_found name=#{params[:name]}")
                halt json_error('provider_not_found', "Provider '#{params[:name]}' not found or disabled", status_code: 404)
              end

              log.debug("[llm][api][providers] action=found name=#{params[:name]}")
              json_response({
                              name:          provider_name,
                              enabled:       true,
                              default_model: Legion::LLM::Settings.config_value(provider_config, :default_model),
                              health:        Legion::LLM::API::Native::Providers.provider_health(provider_name),
                              instances:     Legion::LLM::Call::Registry.instances_for(provider_name.to_sym).map do |inst_id, _adapter|
                                               { id: inst_id.to_s }
                                             end,
                              native:        Legion::LLM::Call::Registry.registered?(provider_name.to_sym),
                              config:        Legion::LLM::API::Native::Providers.safe_config(provider_config)
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.providers.get')
              json_error('provider_error', e.message, status_code: 500)
            end

            log.debug('[llm][api][providers] provider routes registered')
          end

          def self.find_provider_config(name)
            providers = settings_value(:providers, {})
            providers[name.to_sym] || providers[name.to_s]
          end

          def self.enabled_provider_config?(config)
            config.is_a?(Hash) && Legion::LLM::Settings.config_value(config, :enabled, true) != false
          end

          def self.settings_value(key, default = nil)
            Legion::LLM::Settings.value(key, default: default)
          end

          def self.safe_config(config)
            config.each_with_object({}) do |(key, value), safe|
              safe[key] = redact_value(value) unless SECRET_KEYS.include?(key.to_s)
            end
          end

          def self.redact_value(value)
            case value
            when Hash
              safe_config(value)
            when Array
              value.map { |entry| redact_value(entry) }
            else
              value
            end
          end

          def self.provider_health(name)
            if Legion::LLM::Router.routing_enabled?
              tracker = Legion::LLM::Router.health_tracker
              provider_key = name.to_sym
              { circuit_state: tracker.circuit_state(provider_key).to_s,
                adjustment:    tracker.adjustment(provider_key) }
            else
              { circuit_state: 'unknown' }
            end
          end
        end
      end
    end
  end
end
