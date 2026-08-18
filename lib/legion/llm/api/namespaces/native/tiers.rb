# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/logging/helper'
require 'legion/llm/api/native/tiers'

module Legion
  module LLM
    module API
      module Namespaces
        module Native
          module Tiers
            extend Legion::Logging::Helper

            TIERS_CACHE_TTL  = 30 # seconds
            TIERS_CACHE_LOCK = Mutex.new
            @tiers_cache_data = nil
            @tiers_cache_at   = nil

            def self.tiers_tree
              TIERS_CACHE_LOCK.synchronize do
                now = Time.now.to_i
                if @tiers_cache_data.nil? || (now - (@tiers_cache_at || 0)) > TIERS_CACHE_TTL
                  @tiers_cache_data = Legion::LLM::API::Native::Tiers.build_tiers_tree
                  @tiers_cache_at   = now
                  log.debug('[llm][api][namespaces][tiers] action=cache_rebuilt')
                end
                @tiers_cache_data
              end
            end

            def self.reset_cache!
              TIERS_CACHE_LOCK.synchronize do
                @tiers_cache_data = nil
                @tiers_cache_at   = nil
              end
            end

            def self.registered(ns_context) # rubocop:disable Metrics/AbcSize
              log.debug('[llm][api][namespaces][tiers] registering routes')

              ns_context.get '' do
                require_llm!

                tiers_data = Tiers.tiers_tree
                json_response({
                                tiers:        tiers_data,
                                priority:     Legion::LLM::Router.tier_priority,
                                privacy_mode: Legion::LLM::Router.privacy_mode?
                              })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.list')
                json_error('tiers_error', e.message, status_code: 500)
              end

              ns_context.get '/:tier' do
                require_llm!

                tier_name = params[:tier].to_s
                tiers_data = Tiers.tiers_tree
                tier = tiers_data[tier_name]
                halt json_error('tier_not_found', "Tier '#{tier_name}' not found", status_code: 404) unless tier

                json_response({ tier: tier_name, **tier })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.get')
                json_error('tiers_error', e.message, status_code: 500)
              end

              ns_context.get '/:tier/providers' do
                require_llm!

                tier_name = params[:tier].to_s
                tiers_data = Tiers.tiers_tree
                tier = tiers_data[tier_name]
                halt json_error('tier_not_found', "Tier '#{tier_name}' not found", status_code: 404) unless tier

                json_response({ tier: tier_name, providers: tier[:providers] })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.providers')
                json_error('tiers_error', e.message, status_code: 500)
              end

              ns_context.get '/:tier/providers/:provider' do
                require_llm!

                tier_name = params[:tier].to_s
                provider_name = params[:provider].to_s
                tiers_data = Tiers.tiers_tree
                tier = tiers_data[tier_name]
                halt json_error('tier_not_found', "Tier '#{tier_name}' not found", status_code: 404) unless tier

                provider = tier.dig(:providers, provider_name)
                halt json_error('provider_not_found', "Provider '#{provider_name}' not found in tier '#{tier_name}'", status_code: 404) unless provider

                json_response({ tier: tier_name, provider: provider_name, **provider })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.provider')
                json_error('tiers_error', e.message, status_code: 500)
              end

              ns_context.get '/:tier/providers/:provider/instances' do
                require_llm!

                tier_name = params[:tier].to_s
                provider_name = params[:provider].to_s
                tiers_data = Tiers.tiers_tree
                tier = tiers_data[tier_name]
                halt json_error('tier_not_found', "Tier '#{tier_name}' not found", status_code: 404) unless tier

                provider = tier.dig(:providers, provider_name)
                halt json_error('provider_not_found', "Provider '#{provider_name}' not found in tier '#{tier_name}'", status_code: 404) unless provider

                json_response({ tier: tier_name, provider: provider_name, instances: provider[:instances] })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.instances')
                json_error('tiers_error', e.message, status_code: 500)
              end

              ns_context.get '/:tier/providers/:provider/instances/:instance' do
                require_llm!

                tier_name = params[:tier].to_s
                provider_name = params[:provider].to_s
                instance_name = params[:instance].to_s
                tiers_data = Tiers.tiers_tree
                tier = tiers_data[tier_name]
                halt json_error('tier_not_found', "Tier '#{tier_name}' not found", status_code: 404) unless tier

                provider = tier.dig(:providers, provider_name)
                halt json_error('provider_not_found', "Provider '#{provider_name}' not found in tier '#{tier_name}'", status_code: 404) unless provider

                instance = provider.dig(:instances, instance_name)
                halt json_error('instance_not_found', "Instance '#{instance_name}' not found", status_code: 404) unless instance

                json_response({ tier: tier_name, provider: provider_name, instance: instance_name, **instance })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.instance')
                json_error('tiers_error', e.message, status_code: 500)
              end

              ns_context.get '/:tier/providers/:provider/instances/:instance/models' do
                require_llm!

                tier_name = params[:tier].to_s
                provider_name = params[:provider].to_s
                instance_name = params[:instance].to_s
                tiers_data = Tiers.tiers_tree
                tier = tiers_data[tier_name]
                halt json_error('tier_not_found', "Tier '#{tier_name}' not found", status_code: 404) unless tier

                provider = tier.dig(:providers, provider_name)
                halt json_error('provider_not_found', "Provider '#{provider_name}' not found in tier '#{tier_name}'", status_code: 404) unless provider

                instance = provider.dig(:instances, instance_name)
                halt json_error('instance_not_found', "Instance '#{instance_name}' not found", status_code: 404) unless instance

                json_response({ tier: tier_name, provider: provider_name, instance: instance_name, models: instance[:models] })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.instance_models')
                json_error('tiers_error', e.message, status_code: 500)
              end

              ns_context.get '/:tier/providers/:provider/models' do
                require_llm!

                tier_name = params[:tier].to_s
                provider_name = params[:provider].to_s
                tiers_data = Tiers.tiers_tree
                tier = tiers_data[tier_name]
                halt json_error('tier_not_found', "Tier '#{tier_name}' not found", status_code: 404) unless tier

                provider = tier.dig(:providers, provider_name)
                halt json_error('provider_not_found', "Provider '#{provider_name}' not found in tier '#{tier_name}'", status_code: 404) unless provider

                all_models = provider[:instances].values.flat_map { |inst| inst[:models] }
                seen = {}
                unique_models = all_models.select { |m| seen[m[:id]] ? false : (seen[m[:id]] = true) }

                json_response({ tier: tier_name, provider: provider_name, models: unique_models })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.provider_models')
                json_error('tiers_error', e.message, status_code: 500)
              end

              log.debug('[llm][api][namespaces][tiers] routes registered')
            end
          end
        end
      end
    end
  end
end
