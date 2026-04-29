# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Native
        module Instances
          extend Legion::Logging::Helper

          def self.registered(app)
            log.debug('[llm][api][instances] registering provider instance inventory routes')

            app.get '/api/llm/instances' do
              log.debug('[llm][api][instances] action=list_instances')
              require_llm!

              offerings = Legion::LLM::Inventory.offerings
              instances = Legion::LLM::API::Native::Instances.instances_from_offerings(offerings)

              json_response({
                              instances: instances,
                              summary:   {
                                total:     instances.size,
                                providers: instances.map { |instance| instance[:provider_family] }.uniq.size
                              }
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.instances.list')
              json_error('instance_inventory_error', e.message, status_code: 500)
            end

            app.get '/api/llm/instances/:id' do
              instance_id = params[:id]
              log.debug("[llm][api][instances] action=get_instance id=#{instance_id}")
              require_llm!

              offerings = Legion::LLM::Inventory.offerings(instance_id: instance_id)
              instance = Legion::LLM::API::Native::Instances.instance_from_offerings(instance_id, offerings)
              halt json_error('instance_not_found', "Instance '#{instance_id}' not found", status_code: 404) unless instance

              json_response({ instance: instance })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.instances.get')
              json_error('instance_inventory_error', e.message, status_code: 500)
            end

            log.debug('[llm][api][instances] provider instance inventory routes registered')
          end

          def self.instances_from_offerings(offerings)
            instances = offerings.group_by { |offering| offering[:instance_id] }.filter_map do |instance_id, rows|
              instance_from_offerings(instance_id, rows)
            end
            instances.sort_by { |instance| instance[:instance_id] }
          end

          def self.instance_from_offerings(instance_id, offerings)
            rows = Array(offerings)
            return nil if rows.empty?

            {
              instance_id:     instance_id.to_s,
              provider_family: rows.map { |offering| offering[:provider_family] }.uniq.sort.join(','),
              tiers:           rows.map { |offering| offering[:tier].to_s }.uniq.sort,
              transports:      rows.map { |offering| offering[:transport].to_s }.uniq.sort,
              health:          aggregate_health(rows),
              capacity:        aggregate_capacity(rows),
              offerings:       rows.sort_by { |offering| offering[:offering_id].to_s }
            }
          end

          def self.aggregate_health(offerings)
            states = offerings.filter_map { |offering| offering.dig(:health, :circuit_state) }.uniq.sort
            { circuit_states: states }
          end

          def self.aggregate_capacity(offerings)
            {
              max_context_window: offerings.filter_map { |offering| offering.dig(:limits, :context_window) }.max,
              max_output_tokens:  offerings.filter_map { |offering| offering.dig(:limits, :max_output_tokens) }.max,
              offering_count:     offerings.size
            }.compact
          end
        end
      end
    end
  end
end
