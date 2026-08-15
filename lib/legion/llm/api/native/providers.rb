# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Native
        module Providers
          extend Legion::Logging::Helper

          def self.registered(app)
            log.debug('[llm][api][providers] registering provider routes')

            app.get '/api/llm/providers' do
              log.debug('[llm][api][providers] action=list_providers')
              require_llm!

              instances = begin
                Legion::LLM::Call::Registry.all_instances
              rescue StandardError => e
                handle_exception(e, level: :warn, handled: true, operation: 'llm.api.providers.registry_read')
                []
              end

              provider_list = instances.map do |entry|
                Legion::LLM::API::Native::Providers.instance_to_hash(entry)
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
              provider_sym = provider_name.to_sym

              instances = begin
                Legion::LLM::Call::Registry.all_instances
              rescue StandardError => e
                handle_exception(e, level: :warn, handled: true, operation: 'llm.api.providers.registry_read')
                []
              end

              family = instances.select { |entry| entry[:provider].to_sym == provider_sym }

              unless family.any?
                log.debug("[llm][api][providers] action=not_found name=#{params[:name]}")
                halt json_error('provider_not_found',
                                "Provider '#{params[:name]}' not found",
                                status_code: 404)
              end

              provider_list = family.map do |entry|
                Legion::LLM::API::Native::Providers.instance_to_hash(entry)
              end

              log.debug("[llm][api][providers] action=found name=#{params[:name]} instances=#{provider_list.size}")
              json_response({ provider: provider_name, instances: provider_list })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.providers.get')
              json_error('provider_error', e.message, status_code: 500)
            end

            log.debug('[llm][api][providers] provider routes registered')
          end

          def self.instance_to_hash(entry)
            provider_key = entry[:provider].to_sym
            instance_key = entry[:instance].to_sym

            # D14: display health/capabilities live in the per-instance settings
            # hash the provider's discovery actor writes after each registry
            # commit (the visibility surface). The Registry AvailabilityFact
            # remains the routing authority. entry[:instance] is the config name
            # (Call::Registry keys instances by the operator config name), which
            # is exactly the settings key the actor writes under.
            instance_settings = begin
              cfg = Legion::Settings.dig(:extensions, :llm, provider_key, :instances, instance_key)
              cfg.is_a?(Hash) ? cfg : {}
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'api.providers.instance_settings')
              {}
            end

            tier = instance_settings[:tier] || entry.dig(:metadata, :tier)
            capabilities = Array(instance_settings[:capabilities]).map(&:to_s)
            capabilities = Array(entry.dig(:metadata, :capabilities)).map(&:to_s) if capabilities.empty?

            result = {
              provider:     entry[:provider].to_s,
              instance:     entry[:instance].to_s,
              tier:         tier&.to_s,
              capabilities: capabilities,
              health:       instance_settings[:health] || {},
              native:       true
            }
            result[:source] = entry.dig(:metadata, :source) if entry.dig(:metadata, :source)
            result[:credential_fingerprint] = entry.dig(:metadata, :credential_fingerprint) if entry.dig(:metadata, :credential_fingerprint)
            result
          end
        end
      end
    end
  end
end
