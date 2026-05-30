# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/logging/helper'
require 'legion/llm/api/native/instances'

module Legion
  module LLM
    module API
      module Namespaces
        module Native
          module Instances
            extend Legion::Logging::Helper

            def self.registered(ns_context)
              log.debug('[llm][api][namespaces][instances] registering routes')

              ns_context.get '' do
                log.debug('[llm][api][namespaces][instances] action=list_instances')
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

              ns_context.get '/*' do
                instance_id = params[:splat].join('/')
                log.debug("[llm][api][namespaces][instances] action=get_instance id=#{instance_id}")
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

              log.debug('[llm][api][namespaces][instances] routes registered')
            end
          end
        end
      end
    end
  end
end
