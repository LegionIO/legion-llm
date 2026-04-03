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
            nil
          end
        end

        def record(response, model)
          return unless metering_available?

          payload = extract_metering_data(response, model)
          return if payload[:input_tokens].zero? && payload[:output_tokens].zero?

          publish_metering(payload)
        rescue StandardError => e
          handle_exception(e, level: :debug)
        end

        def extract_metering_data(response, model)
          usage = extract_usage(response)
          {
            provider:      extract_provider(response),
            model_id:      (extract_model(response) || model).to_s,
            input_tokens:  usage[:input_tokens],
            output_tokens: usage[:output_tokens],
            event_type:    'llm_completion',
            status:        response.is_a?(Hash) && response[:error] ? 'failure' : 'success'
          }
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

        def publish_metering(payload)
          if gateway_metering?
            Legion::Extensions::LLM::Gateway::Runners::MeteringWriter.write_metering_record(payload)
          elsif transport_metering?
            Legion::Transport.publish(
              'lex.metering.record',
              Legion::JSON.dump(payload)
            )
          end
        end

        def gateway_metering?
          defined?(Legion::Extensions::LLM::Gateway::Runners::MeteringWriter)
        end

        def transport_metering?
          defined?(Legion::Transport) &&
            Legion::Transport.respond_to?(:connected?) &&
            Legion::Transport.connected?
        rescue StandardError => e
          handle_exception(e, level: :debug)
          false
        end

        def metering_available?
          gateway_metering? || transport_metering?
        end
      end
    end
  end
end
