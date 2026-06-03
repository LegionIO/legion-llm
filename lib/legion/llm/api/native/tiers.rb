# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Native
        module Tiers
          extend Legion::Logging::Helper

          def self.registered(app) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
            log.debug('[llm][api][tiers] registering tier routes')

            app.get '/api/llm/tiers' do
              require_llm!

              tiers_data = Legion::LLM::API::Native::Tiers.build_tiers_tree
              json_response({
                              tiers:        tiers_data,
                              priority:     Legion::LLM::API::Native::Tiers.tier_priority,
                              privacy_mode: Legion::LLM::API::Native::Tiers.privacy_mode?
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.list')
              json_error('tiers_error', e.message, status_code: 500)
            end

            app.get '/api/llm/tiers/:tier' do
              require_llm!

              tier_name = params[:tier].to_s
              tiers_data = Legion::LLM::API::Native::Tiers.build_tiers_tree
              tier = tiers_data[tier_name]
              halt json_error('tier_not_found', "Tier '#{tier_name}' not found", status_code: 404) unless tier

              json_response({ tier: tier_name, **tier })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.get')
              json_error('tiers_error', e.message, status_code: 500)
            end

            app.get '/api/llm/tiers/:tier/providers' do
              require_llm!

              tier_name = params[:tier].to_s
              tiers_data = Legion::LLM::API::Native::Tiers.build_tiers_tree
              tier = tiers_data[tier_name]
              halt json_error('tier_not_found', "Tier '#{tier_name}' not found", status_code: 404) unless tier

              json_response({ tier: tier_name, providers: tier[:providers] })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.providers')
              json_error('tiers_error', e.message, status_code: 500)
            end

            app.get '/api/llm/tiers/:tier/providers/:provider' do
              require_llm!

              tier_name = params[:tier].to_s
              provider_name = params[:provider].to_s
              tiers_data = Legion::LLM::API::Native::Tiers.build_tiers_tree
              tier = tiers_data[tier_name]
              halt json_error('tier_not_found', "Tier '#{tier_name}' not found", status_code: 404) unless tier

              provider = tier.dig(:providers, provider_name)
              halt json_error('provider_not_found', "Provider '#{provider_name}' not found in tier '#{tier_name}'", status_code: 404) unless provider

              json_response({ tier: tier_name, provider: provider_name, **provider })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.provider')
              json_error('tiers_error', e.message, status_code: 500)
            end

            app.get '/api/llm/tiers/:tier/providers/:provider/instances' do
              require_llm!

              tier_name = params[:tier].to_s
              provider_name = params[:provider].to_s
              tiers_data = Legion::LLM::API::Native::Tiers.build_tiers_tree
              tier = tiers_data[tier_name]
              halt json_error('tier_not_found', "Tier '#{tier_name}' not found", status_code: 404) unless tier

              provider = tier.dig(:providers, provider_name)
              halt json_error('provider_not_found', "Provider '#{provider_name}' not found in tier '#{tier_name}'", status_code: 404) unless provider

              json_response({ tier: tier_name, provider: provider_name, instances: provider[:instances] })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.tiers.instances')
              json_error('tiers_error', e.message, status_code: 500)
            end

            app.get '/api/llm/tiers/:tier/providers/:provider/instances/:instance' do
              require_llm!

              tier_name = params[:tier].to_s
              provider_name = params[:provider].to_s
              instance_name = params[:instance].to_s
              tiers_data = Legion::LLM::API::Native::Tiers.build_tiers_tree
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

            app.get '/api/llm/tiers/:tier/providers/:provider/instances/:instance/models' do
              require_llm!

              tier_name = params[:tier].to_s
              provider_name = params[:provider].to_s
              instance_name = params[:instance].to_s
              tiers_data = Legion::LLM::API::Native::Tiers.build_tiers_tree
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

            app.get '/api/llm/tiers/:tier/providers/:provider/models' do
              require_llm!

              tier_name = params[:tier].to_s
              provider_name = params[:provider].to_s
              tiers_data = Legion::LLM::API::Native::Tiers.build_tiers_tree
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

            log.debug('[llm][api][tiers] tier routes registered')
          end

          def self.tier_priority
            return Legion::LLM::Router.tier_priority if defined?(Legion::LLM::Router)

            routing_config = Legion::Settings[:llm][:routing] || {}
            top_level = Legion::Settings[:llm][:tier_order] || nil
            Array(top_level || routing_config[:tier_order] || routing_config[:tier_priority] ||
                  %w[local direct fleet cloud frontier])
          end

          def self.privacy_mode?
            return false unless defined?(Legion::LLM::Router)

            Legion::LLM::Router.respond_to?(:privacy_mode?) && Legion::LLM::Router.privacy_mode?
          end

          def self.tier_available?(tier_sym)
            return true unless defined?(Legion::LLM::Router) && Legion::LLM::Router.respond_to?(:tier_available?)

            Legion::LLM::Router.tier_available?(tier_sym)
          end

          def self.build_tiers_tree
            offerings = Legion::LLM::Inventory.offerings({})
            grouped = {}

            offerings.each do |offering|
              tier_name = (offering[:tier] || :unknown).to_s
              provider_name = (offering[:provider_family] || :unknown).to_s
              instance_name = (offering[:instance_id] || offering[:provider_instance] || :default).to_s

              grouped[tier_name] ||= { available: tier_available?(tier_name.to_sym), providers: {} }
              grouped[tier_name][:providers][provider_name] ||= { instances: {} }
              grouped[tier_name][:providers][provider_name][:instances][instance_name] ||= {
                health:       offering_instance_health(provider_name, instance_name),
                capabilities: [],
                models:       []
              }

              inst = grouped[tier_name][:providers][provider_name][:instances][instance_name]
              inst[:capabilities] = (inst[:capabilities] + Array(offering[:capabilities])).uniq.sort
              inst[:models] << build_model_entry(offering)
            end

            # Sort tiers by priority order
            priority = tier_priority
            sorted = {}
            priority.each { |t| sorted[t] = grouped.delete(t) if grouped.key?(t) }
            grouped.each { |t, v| sorted[t] = v }

            # Ensure all priority tiers appear even if empty
            priority.each do |t|
              sorted[t] ||= { available: tier_available?(t.to_sym), providers: {} }
            end

            sorted
          end

          def self.build_model_entry(offering)
            {
              id:           offering[:model].to_s,
              offering_id:  offering[:offering_id] || offering[:id],
              type:         offering[:type].to_s,
              capabilities: Array(offering[:capabilities]).map(&:to_s),
              limits:       offering[:limits] || {},
              enabled:      offering[:enabled] != false,
              cost:         offering[:cost] || {},
              model_family: offering[:model_family]&.to_s
            }.compact
          end

          def self.offering_instance_health(provider_name, instance_name)
            return 'unknown' unless defined?(Legion::LLM::Router) && Legion::LLM::Router.respond_to?(:health_tracker)

            tracker = Legion::LLM::Router.health_tracker
            return 'unknown' unless tracker

            tracker.circuit_state(provider_name.to_sym, instance: instance_name.to_sym).to_s
          rescue StandardError => e
            log.debug "[llm][tiers] action=offering_instance_health provider=#{provider_name} instance=#{instance_name} error=#{e.class} — #{e.message}"
            'unknown'
          end
        end
      end
    end
  end
end
