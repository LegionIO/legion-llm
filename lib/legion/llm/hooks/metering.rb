# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Hooks
      module Metering
        extend Legion::Logging::Helper

        module_function

        def install
          Legion::LLM::Hooks.after_chat do |response:, model:, **|
            record(response, model)
          end
        end

        def record(response, model)
          return unless metering_available?

          data = extract_metering_data(response, model)
          return if data[:input_tokens].zero? && data[:output_tokens].zero?

          publish_metering(data)
          nil
        rescue StandardError => e
          handle_exception(e, level: :warn)
          nil
        end

        def extract_metering_data(response, model)
          usage = extract_usage(response)
          resolved_model    = extract_model_id(response) || model.to_s
          resolved_provider = extract_provider(response)

          status = response.is_a?(Hash) && response[:error] ? 'failure' : 'success'

          {
            provider:      resolved_provider,
            model_id:      resolved_model,
            input_tokens:  usage[:input_tokens],
            output_tokens: usage[:output_tokens],
            event_type:    'llm_completion',
            status:        status
          }
        end

        def metering_available?
          gateway_metering? || transport_metering?
        end

        def gateway_metering?
          defined?(LegionLLMGateway) && LegionLLMGateway.respond_to?(:emit)
        end

        def transport_metering?
          defined?(Legion::LLM::Transport::Messages::MeteringEvent)
        end

        def publish_metering(data)
          if gateway_metering?
            LegionLLMGateway.emit(data)
          elsif transport_metering?
            Legion::LLM::Metering.emit(data)
          end
        rescue StandardError => e
          handle_exception(e, level: :warn)
        end

        def extract_usage(response)
          return { input_tokens: 0, output_tokens: 0 } unless response.is_a?(Hash)

          usage = response[:usage] || {}
          {
            input_tokens:  usage[:input_tokens]  || usage[:prompt_tokens]     || 0,
            output_tokens: usage[:output_tokens] || usage[:completion_tokens] || 0
          }
        end

        def extract_model_id(response)
          return nil unless response.is_a?(Hash)

          response.dig(:meta, :model) || response[:model]
        end

        def extract_provider(response)
          return nil unless response.is_a?(Hash)

          response.dig(:meta, :provider) || response[:provider]
        end
      end
    end
  end
end
