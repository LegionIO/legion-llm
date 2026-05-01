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

              instances = Legion::LLM::API::Native::Instances.registry_instances

              json_response({
                              instances: instances,
                              summary:   {
                                total:     instances.size,
                                providers: instances.map { |inst| inst[:provider] }.uniq.size
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

              result = Legion::LLM::API::Native::Instances.find_registry_instance(instance_id)
              if result == :ambiguous
                halt json_error('ambiguous_instance_id',
                                "Instance id '#{instance_id}' matches multiple providers; " \
                                'use composite id (provider/instance) to disambiguate',
                                status_code: 400)
              end
              halt json_error('instance_not_found', "Instance '#{instance_id}' not found", status_code: 404) unless result

              json_response({ instance: result })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.instances.get')
              json_error('instance_inventory_error', e.message, status_code: 500)
            end

            log.debug('[llm][api][instances] provider instance inventory routes registered')
          end

          def self.registry_instances
            instances = []
            Legion::LLM::Call::Registry.available.each do |provider_name|
              Legion::LLM::Call::Registry.instances_for(provider_name).each_key do |inst_id|
                instances << {
                  id:       "#{provider_name}/#{inst_id}",
                  provider: provider_name.to_s,
                  instance: inst_id.to_s
                }
              end
            end
            instances.sort_by { |inst| inst[:id] }
          end

          def self.find_registry_instance(instance_id)
            # Try exact composite id match first (e.g. "ollama/local")
            exact = registry_instances.find { |inst| inst[:id] == instance_id }
            return exact if exact

            # Fall back to bare instance name, but guard against ambiguity
            matches = registry_instances.select { |inst| inst[:instance] == instance_id }
            return matches.first if matches.size == 1
            return :ambiguous if matches.size > 1

            # No match found
            nil
          end
        end
      end
    end
  end
end
