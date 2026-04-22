# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module Rbac
          include Legion::Logging::Helper

          def step_rbac
            start_time = Time.now

            unless defined?(::Legion::Rbac)
              if fleet_caller? || !fail_open_permitted?
                msg = '503: RBAC unavailable — request denied ' \
                      "(fleet=#{fleet_caller?}, fail_open=#{fail_open_permitted?})"
                log.error("[llm][rbac] blocked request_id=#{@request.id} reason=rbac_unavailable " \
                          "fleet=#{fleet_caller?} fail_open=#{fail_open_permitted?}")
                record_rbac_audit(:failure, msg, start_time)
                record_rbac_timeline("denied: #{msg}")
                raise Legion::LLM::PipelineError.new(msg, step: :rbac)
              end

              log.warn('[llm][rbac] RBAC unavailable, permitting request (fail_open enabled) ' \
                       "request_id=#{@request.id}")
              @warnings << 'RBAC unavailable, permitting request (fail_open enabled)'
              record_rbac_audit(:success, 'permitted (rbac unavailable, fail_open enabled)', start_time)
              record_rbac_timeline('permitted (rbac unavailable, fail_open enabled)')
              return
            end

            begin
              principal = build_rbac_principal
              caller_id = extract_rbac_caller_id
              log.info("[llm][rbac] authorize request_id=#{@request.id} caller=#{caller_id}")
              ::Legion::Rbac.authorize!(principal: principal, action: :use, resource: 'llm/pipeline')

              log.info("[llm][rbac] permitted request_id=#{@request.id} caller=#{caller_id}")
              record_rbac_audit(:success, "permitted caller=#{caller_id}", start_time)
              record_rbac_timeline("permitted caller=#{caller_id}")
            rescue ::Legion::Rbac::AccessDenied => e
              log.warn("[llm][rbac] denied request_id=#{@request.id} error=#{e.message}")
              record_rbac_audit(:failure, e.message, start_time)
              record_rbac_timeline("denied: #{e.message}")
              handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.rbac.denied', request_id: @request.id)
              raise Legion::LLM::PipelineError.new("403 Forbidden: #{e.message}", step: :rbac)
            rescue StandardError => e
              log.error("[llm][rbac] failed request_id=#{@request.id} error=#{e.message}")
              record_rbac_audit(:failure, "error: #{e.message}", start_time)
              record_rbac_timeline("error: #{e.message}")
              handle_exception(e, level: :error, operation: 'llm.pipeline.steps.rbac', request_id: @request.id)
              raise Legion::LLM::PipelineError.new("rbac error: #{e.message}", step: :rbac)
            end
          end

          private

          def fail_open_permitted?
            setting = Legion::Settings.dig(:rbac, :fail_open)
            setting.nil? || setting
          end

          def build_rbac_principal
            rb = @request.caller&.fetch(:requested_by, {}) || {}
            ::Legion::Rbac::Principal.new(
              id:    rb[:id] || rb[:identity] || 'anonymous',
              type:  rb[:type] || :human,
              roles: rb[:roles] || [],
              team:  rb[:team]
            )
          end

          def fleet_caller?
            agent_ids = [
              @request.agent&.dig(:id),
              @request.caller&.dig(:agent, :id)
            ]

            agent_ids.any? { |agent_id| agent_id.is_a?(String) && agent_id.start_with?('fleet:') }
          end

          def extract_rbac_caller_id
            @request.caller&.dig(:requested_by, :id) ||
              @request.caller&.dig(:requested_by, :identity) ||
              'anonymous'
          end

          def record_rbac_audit(outcome, detail, start_time)
            @audit[:'rbac:permission_check'] = {
              outcome:     outcome,
              detail:      detail,
              duration_ms: ((Time.now - start_time) * 1000).to_i,
              timestamp:   Time.now
            }
          end

          def record_rbac_timeline(detail)
            @timeline.record(
              category:  :audit,
              key:       'rbac:permission_check',
              direction: :internal,
              detail:    detail,
              from:      'pipeline',
              to:        'rbac'
            )
          end
        end
      end
    end
  end
end
