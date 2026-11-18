# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/inventory'
require 'legion/llm/call/registry'

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

              snapshot = Legion::LLM::Inventory.snapshot
              provider_list = Legion::LLM::API::Native::Providers.instances(snapshot: snapshot)

              summary = {
                total:           provider_list.size,
                native:          provider_list.count { |p| p[:native] },
                routing_enabled: provider_list.any?
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
              snapshot = Legion::LLM::Inventory.snapshot
              family = Legion::LLM::API::Native::Providers.instances(snapshot: snapshot, provider: provider_name)

              unless family.any?
                log.debug("[llm][api][providers] action=not_found name=#{params[:name]}")
                halt json_error('provider_not_found',
                                "Provider '#{params[:name]}' not found",
                                status_code: 404)
              end

              provider_list = family

              log.debug("[llm][api][providers] action=found name=#{params[:name]} instances=#{provider_list.size}")
              json_response({ provider: provider_name, instances: provider_list })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.providers.get')
              json_error('provider_error', e.message, status_code: 500)
            end

            log.debug('[llm][api][providers] provider routes registered')
          end

          # Configuration and adapter registration are not executable inventory.
          # Both route trees project the same immutable, complete publication.
          def self.instances(snapshot:, provider: nil)
            snapshot.each_instance.filter_map do |record|
              next if provider && record.instance_key.provider_family.to_s != provider.to_s

              instance_to_hash(record)
            end
          end

          def self.instance_to_hash(record)
            key = record.instance_key
            lanes = record.lanes_by_id.values
            availability = record.availability
            # Provenance is diagnostic metadata, never a source of catalog,
            # capability, tier or health facts.
            metadata = Legion::LLM::Call::Registry.metadata_for(key.provider_family, key.instance_id)
            capabilities = lanes.flat_map do |lane|
              lane.capability_evidence.filter_map { |capability, evidence| capability.to_s if evidence.supported? }
            end.uniq.sort
            result = {
              provider:     key.provider_family.to_s,
              instance:     key.instance_id,
              tier:         lanes.first&.tier&.to_s,
              capabilities: capabilities,
              health:       {
                state:              availability.state.to_s,
                reason:             availability.reason,
                observed_at:        availability.observed_at.iso8601,
                last_probe_outcome: availability.last_probe_outcome&.to_s,
                source:             availability.source.to_s
              },
              native:       true
            }
            result[:source] = metadata[:source] if metadata[:source]
            result[:credential_fingerprint] = metadata[:credential_fingerprint] if metadata[:credential_fingerprint]
            result
          end
        end
      end
    end
  end
end
