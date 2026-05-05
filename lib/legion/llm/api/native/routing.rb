# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Native
        module Routing
          extend Legion::Logging::Helper

          def self.registered(app)
            log.debug('[llm][api][routing] registering routing routes')

            app.get '/api/llm/routing' do
              log.debug('[llm][api][routing] action=list_rules')
              require_llm!

              rules = Legion::LLM::Router.send(:load_rules)
              auto_count = rules.count { |r| r.name.to_s.start_with?('auto:') }
              manual_count = rules.size - auto_count

              rule_list = rules.map do |rule|
                {
                  name:       rule.name,
                  priority:   rule.priority,
                  conditions: rule.conditions,
                  target:     rule.target,
                  constraint: rule.constraint,
                  auto:       rule.name.to_s.start_with?('auto:')
                }.compact
              end

              json_response({
                              routing_enabled:      Legion::LLM::Router.routing_enabled?,
                              auto_rules_populated: Legion::LLM::Router.auto_rules_populated?,
                              rules:                rule_list,
                              summary:              {
                                total:  rules.size,
                                auto:   auto_count,
                                manual: manual_count
                              }
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.routing.list')
              json_error('routing_error', e.message, status_code: 500)
            end

            log.debug('[llm][api][routing] routing routes registered')
          end
        end
      end
    end
  end
end
