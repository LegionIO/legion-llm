# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Steps
        module Rbac
          def step_rbac
            start_time = Time.now

            unless defined?(::Legion::Rbac)
              @warnings << 'RBAC unavailable, permitting request without enforcement'
              record_rbac_audit(:success, 'permitted (rbac unavailable)', start_time)
              record_rbac_timeline('permitted (rbac unavailable)')
              return
            end

            principal = build_rbac_principal
            ::Legion::Rbac.authorize!(principal: principal, action: :use, resource: 'llm/pipeline')

            caller_id = extract_rbac_caller_id
            record_rbac_audit(:success, "permitted caller=#{caller_id}", start_time)
            record_rbac_timeline("permitted caller=#{caller_id}")
          rescue ::Legion::Rbac::AccessDenied => e
            record_rbac_audit(:failure, e.message, start_time)
            record_rbac_timeline("denied: #{e.message}")
            raise Legion::LLM::PipelineError.new("403 Forbidden: #{e.message}", step: :rbac)
          end

          private

          def build_rbac_principal
            rb = @request.caller&.fetch(:requested_by, {}) || {}
            ::Legion::Rbac::Principal.new(
              id:    rb[:id] || rb[:identity] || 'anonymous',
              type:  rb[:type] || :human,
              roles: rb[:roles] || [],
              team:  rb[:team]
            )
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
