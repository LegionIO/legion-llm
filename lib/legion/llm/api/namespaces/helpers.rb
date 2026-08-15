# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/api/shared_helpers'
require 'legion/llm/api/error_translator'
require 'legion/llm/inference/executor/payload_builder'

module Legion
  module LLM
    module API
      module Namespaces
        module Helpers
          include Legion::LLM::API::SharedHelpers
          include Legion::LLM::API::ErrorTranslator

          def openai_error(message, type: 'server_error', code: nil, status_code: 500)
            content_type :json
            status status_code
            body = { error: { message: message, type: type } }
            body[:error][:code] = code if code
            Legion::JSON.dump(body)
          end

          def anthropic_error(error_type, message, status_code: 500)
            content_type :json
            status status_code
            Legion::JSON.dump({ type: 'error', error: { type: error_type, message: message } })
          end

          def detect_client(rack_env)
            return :anthropic if rack_env['HTTP_ANTHROPIC_VERSION']
            return :anthropic if rack_env['HTTP_X_API_KEY'] && !rack_env['HTTP_AUTHORIZATION']

            :openai
          end

          def require_data!
            return if data_subsystem_available?

            halt 503, { 'Content-Type' => 'application/json' },
                 Legion::JSON.dump({ error: { code:    'data_required',
                                              message: 'Legion::Data is required for this operation',
                                              type:    'server_error' } })
          end

          # G31 / opus M7: validate x-legion-* routing headers against Taxonomies at ingress.
          # Raises Errors::InvalidHeader if any header contains an unknown value.
          # Called by inference routes before building the executor request.
          def validate_legion_routing_headers!(rack_env)
            http_headers = rack_env.select { |k, _| k.start_with?('HTTP_') }

            # Build a flat header map from Rack env (HTTP_X_LEGION_TIERS → x-legion-tiers)
            mapped = http_headers.each_with_object({}) do |(k, v), h|
              h[k.sub(/^HTTP_/, '').downcase.tr('_', '-')] = v
            end

            # Validate each x-legion taxonomy header
            {
              'x-legion-tiers' => Legion::Extensions::Llm::Taxonomies::TIERS
            }.each do |header_name, taxonomy|
              Legion::LLM::Inference::Executor::PayloadBuilder.parse_and_validate_header(
                headers: mapped, name: header_name, taxonomy: taxonomy
              )
            end
          rescue Legion::LLM::Errors::InvalidHeader
            raise
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.api.validate_legion_routing_headers')
            nil
          end

          def data_subsystem_available?
            defined?(Legion::Data) && Legion::Data.respond_to?(:connected?) && Legion::Data.connected?
          rescue StandardError => e
            log.debug "[llm][api][namespaces][helpers] action=data_subsystem_check_fallback error=#{e.class} message=#{e.message}"
            false
          end
        end
      end
    end
  end
end
