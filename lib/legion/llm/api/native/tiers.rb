# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/router'
require 'legion/extensions/llm/taxonomies'

module Legion
  module LLM
    module API
      module Native
        module Tiers
          extend Legion::Logging::Helper

          def self.registered(app) # rubocop:disable Metrics/AbcSize
            log.debug('[llm][api][tiers] registering tier routes')

            app.get '/api/llm/tiers' do
              require_llm!

              tiers_data = Legion::LLM::API::Native::Tiers.build_tiers_tree
              json_response({
                              tiers:        tiers_data,
                              priority:     Legion::LLM::Router.tier_priority,
                              privacy_mode: Legion::LLM::Router.privacy_mode?
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

          # Legacy display names for operations (the v0.15.2 capabilities
          # display vocabulary used by the tier/offerings surfaces).
          CAPABILITY_NAMES_BY_OPERATION = {
            chat: :completion, stream_chat: :streaming, embed: :embedding, image: :image,
            transcribe: :audio_transcription, translate: :audio_transcription, speak: :audio_speech,
            moderate: :moderation
          }.freeze

          # The tier tree is projected from the Registry snapshot
          # (model_catalog.rb is the in-repo precedent). Instance-level health
          # display derives from the instance's AvailabilityFact — the same
          # fact the provider actors copy into the settings health hash —
          # because the tree is keyed by the derived instance id, which the
          # settings hash (keyed by config name) cannot address. The
          # AvailabilityFact remains the routing authority; this is display.
          def self.build_tiers_tree
            snapshot = Legion::LLM::Inventory.snapshot
            inst_by_key = {}
            snapshot.each_instance { |inst| inst_by_key[inst.instance_key] = inst }

            grouped = {}
            snapshot.each_lane do |lane|
              # Compliance-by-absence: denied models never appear in the tier
              # view (same policy as the offerings surface).
              next unless Legion::LLM::API::Native::Offerings.policy_permits?(lane)

              ik = lane.instance_key
              tier_name = lane.tier.to_s
              provider_name = ik.provider_family.to_s
              instance_name = ik.instance_id.to_s

              grouped[tier_name] ||= { available: Legion::LLM::Router.tier_available?(tier_name.to_sym), providers: {} }
              grouped[tier_name][:providers][provider_name] ||= { instances: {} }
              grouped[tier_name][:providers][provider_name][:instances][instance_name] ||= {
                health:       instance_health_display(inst_by_key[ik]&.availability),
                capabilities: [],
                models:       []
              }

              inst = grouped[tier_name][:providers][provider_name][:instances][instance_name]
              inst[:capabilities] = (inst[:capabilities] + lane_capabilities(lane)).uniq.sort
              inst[:models] << build_model_entry(lane)
            end

            # Sort tiers by priority order. Router.tier_priority yields symbols;
            # the tree is keyed by tier Strings, so normalize to avoid duplicate
            # (symbol + string) keys for the same tier.
            priority = Legion::LLM::Router.tier_priority.map(&:to_s)
            sorted = {}
            priority.each { |t| sorted[t] = grouped.delete(t) if grouped.key?(t) }
            grouped.each { |t, v| sorted[t] = v }

            # Ensure all priority tiers appear even if empty
            priority.each do |t|
              sorted[t] ||= { available: Legion::LLM::Router.tier_available?(t.to_sym), providers: {} }
            end

            sorted
          end

          def self.build_model_entry(lane)
            {
              id:           lane.model.to_s,
              offering_id:  lane.lane_id,
              type:         lane_type(lane).to_s,
              capabilities: lane_capabilities(lane),
              limits:       lane_limits(lane),
              enabled:      true,
              cost:         {},
              model_family: lane.metadata[:model_family]&.to_s
            }.compact
          end

          # Legacy response shape: a single circuit-state string per instance.
          def self.instance_health_display(availability)
            case availability&.state
            when :available then 'closed'
            when :unavailable then 'open'
            else 'unknown'
            end
          end

          # The lane's display capabilities: the representative operation's
          # legacy display name plus every supported capability the provider
          # published as evidence.
          def self.lane_capabilities(lane)
            caps = [CAPABILITY_NAMES_BY_OPERATION.fetch(lane.operation, lane.operation)]
            lane.capability_evidence.each do |capability, evidence|
              caps << capability if evidence.status == :supported
            end
            caps.map(&:to_s)
          end

          def self.lane_limits(lane)
            limits = {}
            limits[:context_window] = lane.context_evidence.value if lane.context_evidence.known?
            limits[:max_output_tokens] = lane.max_output_evidence.value if lane.max_output_evidence.known?
            limits
          end

          def self.lane_type(lane)
            Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: lane.operation)
          end
        end
      end
    end
  end
end
