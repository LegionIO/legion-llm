# frozen_string_literal: true

module Legion
  module LLM
    module Hooks
      module CostTracking
        module_function

        def install
          Legion::LLM::Hooks.after_chat do |response:, model:, **|
            track(response, model)
            nil
          end
        end

        def track(response, model)
          usage = extract_usage(response)
          return if usage[:input_tokens].zero? && usage[:output_tokens].zero?

          CostTracker.record(
            model:         (extract_model(response) || model).to_s,
            input_tokens:  usage[:input_tokens],
            output_tokens: usage[:output_tokens],
            provider:      extract_provider(response)
          )
        rescue StandardError => e
          Legion::Logging.debug("[LLM::CostTracking] track failed: #{e.message}") if defined?(Legion::Logging)
        end

        def extract_usage(response)
          return { input_tokens: 0, output_tokens: 0 } unless response.is_a?(Hash)

          usage = response[:usage] || {}
          {
            input_tokens:  usage[:input_tokens] || usage[:prompt_tokens] || 0,
            output_tokens: usage[:output_tokens] || usage[:completion_tokens] || 0
          }
        end

        def extract_provider(response)
          return nil unless response.is_a?(Hash)

          response.dig(:meta, :provider) || response[:provider]
        end

        def extract_model(response)
          return nil unless response.is_a?(Hash)

          response.dig(:meta, :model) || response[:model]
        end
      end
    end
  end
end
