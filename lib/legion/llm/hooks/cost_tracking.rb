# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Hooks
      module CostTracking
        extend Legion::Logging::Helper

        module_function

        def install
          Legion::LLM::Hooks.after_chat do |response:, model:, **|
            track(response, model)
          end
        end

        def track(response, model)
          usage = extract_usage(response)
          return if usage[:input_tokens].zero? && usage[:output_tokens].zero?

          resolved_model    = extract_model(response) || model.to_s
          resolved_provider = extract_provider(response)

          Legion::LLM::Metering::Recorder.record(
            model:         resolved_model,
            input_tokens:  usage[:input_tokens],
            output_tokens: usage[:output_tokens],
            provider:      resolved_provider
          )
          nil
        rescue StandardError => e
          handle_exception(e, level: :warn)
          nil
        end

        def extract_usage(response)
          return { input_tokens: 0, output_tokens: 0 } unless response.is_a?(Hash)

          usage = response[:usage] || {}
          {
            input_tokens:  usage[:input_tokens]  || usage[:prompt_tokens]     || 0,
            output_tokens: usage[:output_tokens] || usage[:completion_tokens] || 0
          }
        end

        def extract_model(response)
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
