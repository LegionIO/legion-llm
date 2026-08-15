# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/router'

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

          # Legacy display names for supported operations (same mapping the
          # LegacyCoordinatorAdapter and provider actors use for the
          # capabilities display surface).
          CAPABILITY_NAMES_BY_OPERATION = {
            chat: :completion, stream_chat: :streaming, embed: :embedding, image: :image,
            transcribe: :audio_transcription, translate: :audio_transcription, speak: :audio_speech,
            moderate: :moderation
          }.freeze

          # D14: the tier tree is projected from the NEW Registry snapshot
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
            snapshot.each_offering do |offering|
              # Compliance-by-absence: denied models never appear in the tier
              # view (same §9.5 policy as the offerings surface).
              next unless Legion::LLM::API::Native::Offerings.policy_permits?(offering)

              ik = offering.instance_key
              tier_name = offering.tier.to_s
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
              inst[:capabilities] = (inst[:capabilities] + offering_capabilities(offering)).uniq.sort
              inst[:models] << build_model_entry(offering)
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

          def self.build_model_entry(offering)
            {
              id:           offering.model.to_s,
              offering_id:  offering.offering_id.to_s,
              type:         offering.operation_status(operation: :embed) == :supported ? 'embedding' : 'inference',
              capabilities: offering_capabilities(offering),
              limits:       offering_limits(offering),
              enabled:      true,
              cost:         {},
              model_family: offering.metadata[:model_family]&.to_s
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

          def self.offering_capabilities(offering)
            caps = offering.supported_operations.map { |op| CAPABILITY_NAMES_BY_OPERATION.fetch(op, op) }
            offering.capability_evidence.each do |capability, evidence|
              caps << capability if evidence.status == :supported
            end
            caps.map(&:to_s)
          end

          def self.offering_limits(offering)
            limits = {}
            limits[:context_window] = offering.context_evidence.value if offering.context_evidence.known?
            limits[:max_output_tokens] = offering.max_output_evidence.value if offering.max_output_evidence.known?
            limits
          end
        end
      end
    end
  end
end
