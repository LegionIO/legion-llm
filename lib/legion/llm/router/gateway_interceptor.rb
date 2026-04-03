# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Router
      module GatewayInterceptor
        extend Legion::Logging::Helper

        module_function

        def intercept(resolution, context: {})
          return resolution unless gateway_enabled?
          return resolution unless resolution&.tier == :cloud

          model = resolution.model
          risk_tier = context[:risk_tier]&.to_sym

          unless model_allowed?(model, risk_tier)
            log.warn "[llm] gateway policy blocked model=#{model} risk_tier=#{risk_tier}"
            return nil
          end

          Resolution.new(
            tier:     :cloud,
            provider: :gateway,
            model:    model,
            rule:     'gateway_intercept',
            metadata: { original_provider: resolution.provider }
          )
        end

        def gateway_enabled?
          settings = gateway_settings
          settings[:enabled] == true && !settings[:endpoint].nil?
        end

        def model_allowed?(model, risk_tier)
          return true unless risk_tier

          allowlist = gateway_settings.dig(:model_policy, risk_tier)
          return true unless allowlist.is_a?(Array) && !allowlist.empty?

          allowlist.any? { |pattern| File.fnmatch?(pattern, model.to_s) }
        end

        def gateway_headers(context)
          {
            'X-Agent-Id'        => context[:worker_id],
            'X-Tenant-Id'       => context[:tenant_id],
            'X-AIRB-Project-Id' => context[:airb_project_id],
            'X-Risk-Tier'       => context[:risk_tier]&.to_s,
            'X-Legion-Task-Id'  => context[:task_id]&.to_s
          }.compact
        end

        def gateway_settings
          llm = Legion::Settings[:llm]
          return {} unless llm.is_a?(Hash)

          (llm[:gateway] || {}).transform_keys(&:to_sym)
        rescue StandardError => e
          handle_exception(e, level: :warn)
          {}
        end
      end
    end
  end
end
