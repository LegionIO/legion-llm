# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Namespaces
        module Native
          module Routing
            extend Legion::Logging::Helper

            def self.registered(ns_context)
              log.debug('[llm][api][namespaces][routing] registering routes')

              ns_context.get '' do
                log.debug('[llm][api][namespaces][routing] action=list_rules')
                require_llm!

                json_response({
                                routing_enabled:      false,
                                auto_rules_populated: false,
                                rules:                [],
                                summary:              { total: 0, auto: 0, manual: 0 }
                              })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.routing.list')
                json_error('routing_error', e.message, status_code: 500)
              end

              log.debug('[llm][api][namespaces][routing] routes registered')
            end
          end
        end
      end
    end
  end
end
