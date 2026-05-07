# frozen_string_literal: true

require 'legion/extensions/llm/fleet/protocol'
require 'legion/logging/helper'

require_relative '../call/registry'
require_relative 'worker_execution'

module Legion
  module LLM
    module Fleet
      module Handler
        extend Legion::Logging::Helper

        module_function

        LEGACY_FIELDS = %i[schema_version request_type fleet_correlation_id].freeze

        def handle_fleet_request(payload)
          envelope = normalize_hash(payload)
          log.debug '[llm][fleet][handler] action=handle_fleet_request.enter ' \
                    "operation=#{envelope[:operation]} model=#{envelope[:model]} provider=#{envelope[:provider]}"

          validate_envelope!(envelope)
          provider_resolver = proc { |validated_envelope| resolve_provider(validated_envelope) }
          response = WorkerExecution.call(envelope: envelope, provider: provider_resolver)
          result = build_success(envelope, response)
          publish_response(envelope, result) if envelope[:reply_to]
          result
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.handler.handle_fleet_request')
          result = build_error(envelope || {}, e)
          publish_error(envelope || {}, result) if envelope&.[](:reply_to)
          result
        end

        def validate_envelope!(envelope)
          raise ArgumentError, 'invalid_fleet_request: unsupported protocol_version' unless protocol_version?(envelope[:protocol_version])

          required_fields = %i[
            request_id correlation_id operation provider provider_instance model params reply_to
            message_context caller trace_context timeout_seconds expires_at idempotency_key
          ]
          required_fields << :signed_token if responder_auth_required?
          required_fields.each do |key|
            raise ArgumentError, "invalid_fleet_request: #{key} is required" if envelope[key].nil?
          end
          LEGACY_FIELDS.each do |key|
            raise ArgumentError, "invalid_fleet_request: #{key} is not supported" if envelope.key?(key)
          end
        end

        def resolve_provider(envelope)
          provider = envelope[:provider]
          instance = envelope[:provider_instance]
          adapter = Legion::LLM::Call::Registry.for(provider, instance: instance)
          return adapter if adapter

          raise ArgumentError, "provider_not_registered: #{provider}/#{instance}"
        end

        def build_success(envelope, response)
          {
            success:           true,
            protocol_version:  envelope[:protocol_version],
            request_id:        envelope[:request_id],
            correlation_id:    envelope[:correlation_id],
            idempotency_key:   envelope[:idempotency_key],
            operation:         envelope[:operation],
            provider:          envelope[:provider],
            provider_instance: envelope[:provider_instance],
            model:             response_model(response) || envelope[:model],
            reply_to:          envelope[:reply_to],
            message_context:   envelope[:message_context] || {},
            trace_context:     envelope[:trace_context] || {},
            content:           response_content(response),
            tool_calls:        response_tool_calls(response),
            usage:             response_usage(response),
            finish_reason:     response_finish_reason(response),
            metadata:          response_metadata(response)
          }.compact
        end

        def build_error(envelope, error)
          {
            success:           false,
            error:             error_code(error),
            protocol_version:  envelope[:protocol_version] || ::Legion::Extensions::Llm::Fleet::Protocol::VERSION,
            request_id:        envelope[:request_id],
            correlation_id:    envelope[:correlation_id],
            idempotency_key:   envelope[:idempotency_key],
            operation:         envelope[:operation],
            provider:          envelope[:provider],
            provider_instance: envelope[:provider_instance],
            model:             envelope[:model],
            reply_to:          envelope[:reply_to],
            message_context:   envelope[:message_context] || {},
            trace_context:     envelope[:trace_context] || {},
            message:           error.message,
            error_class:       error.class.name
          }.compact
        end

        def publish_response(_envelope, result)
          require 'legion/extensions/llm/transport/messages/fleet_response'
          publish_result = ::Legion::Extensions::Llm::Transport::Messages::FleetResponse.new(
            protocol_version:  result[:protocol_version],
            request_id:        result[:request_id],
            correlation_id:    result[:correlation_id],
            idempotency_key:   result[:idempotency_key],
            operation:         result[:operation],
            provider:          result[:provider],
            provider_instance: result[:provider_instance],
            model:             result[:model],
            reply_to:          result[:reply_to],
            message_context:   result[:message_context],
            trace_context:     result[:trace_context],
            content:           result[:content],
            tool_calls:        result[:tool_calls],
            usage:             result[:usage],
            finish_reason:     result[:finish_reason],
            metadata:          result[:metadata]
          ).publish(reply_publish_options)
          log_reply_publish_failure(publish_result, result[:correlation_id]) unless publish_accepted?(publish_result)
          publish_result
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.handler.publish_response')
        end

        def publish_error(_envelope, result)
          require 'legion/extensions/llm/transport/messages/fleet_error'
          publish_result = ::Legion::Extensions::Llm::Transport::Messages::FleetError.new(
            protocol_version:  result[:protocol_version],
            request_id:        result[:request_id],
            correlation_id:    result[:correlation_id],
            idempotency_key:   result[:idempotency_key],
            operation:         result[:operation],
            provider:          result[:provider],
            provider_instance: result[:provider_instance],
            model:             result[:model],
            reply_to:          result[:reply_to],
            message_context:   result[:message_context],
            trace_context:     result[:trace_context],
            code:              result[:error],
            message:           result[:message],
            error_class:       result[:error_class],
            retryable:         false
          ).publish(reply_publish_options)
          log_reply_publish_failure(publish_result, result[:correlation_id]) unless publish_accepted?(publish_result)
          publish_result
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.handler.publish_error')
        end

        def normalize_hash(hash)
          return {} unless hash.respond_to?(:each)

          hash.each_with_object({}) do |(key, value), result|
            result[key.respond_to?(:to_sym) ? key.to_sym : key] = normalize_value(value)
          end
        end

        def normalize_value(value)
          case value
          when Hash
            normalize_hash(value)
          when Array
            value.map { |entry| normalize_value(entry) }
          else
            value
          end
        end

        def response_content(response)
          return response[:content] || response['content'] || response[:result] || response['result'] if response.is_a?(Hash)
          return response.content if response.respond_to?(:content)

          response
        end

        def response_model(response)
          return response[:model] || response['model'] if response.is_a?(Hash)
          return response.model if response.respond_to?(:model)

          nil
        end

        def response_tool_calls(response)
          return response[:tool_calls] || response['tool_calls'] if response.is_a?(Hash)
          return response.tool_calls if response.respond_to?(:tool_calls)

          nil
        end

        def response_usage(response)
          return response[:usage] || response['usage'] || {} if response.is_a?(Hash)
          return response.tokens if response.respond_to?(:tokens)

          {}
        end

        def response_finish_reason(response)
          return response[:finish_reason] || response['finish_reason'] if response.is_a?(Hash)
          return response.finish_reason if response.respond_to?(:finish_reason)

          nil
        end

        def response_metadata(response)
          return response[:metadata] || response['metadata'] || {} if response.is_a?(Hash)
          return response.metadata if response.respond_to?(:metadata)

          {}
        end

        def error_code(error)
          message = error.message.to_s
          return 'invalid_fleet_request' if message.start_with?('invalid_fleet_request')
          return 'provider_not_registered' if message.start_with?('provider_not_registered')
          return 'fleet_policy_denied' if error.is_a?(WorkerExecution::PolicyError)

          'fleet_worker_error'
        end

        def responder_auth_required?
          value = Legion::LLM::Settings.value(:fleet, :responder, :require_auth, default: nil)
          return value != false unless value.nil?

          Legion::LLM::Settings.value(:fleet, :auth, :require_signed_token, default: true) != false
        end

        def protocol_version?(value)
          value == ::Legion::Extensions::Llm::Fleet::Protocol::VERSION ||
            value == ::Legion::Extensions::Llm::Fleet::Protocol::VERSION.to_s
        end

        def reply_publish_options
          {
            mandatory:                  Legion::LLM::Settings.value(:fleet, :responder, :mandatory, default: false),
            publisher_confirm:          Legion::LLM::Settings.value(:fleet, :responder, :publisher_confirm, default: false),
            publish_confirm_timeout_ms: Legion::LLM::Settings.value(:fleet, :responder, :publish_confirm_timeout_ms, default: 500),
            spool:                      Legion::LLM::Settings.value(:fleet, :responder, :spool, default: false),
            return_result:              true
          }
        end

        def publish_accepted?(publish_result)
          publish_result.is_a?(Hash) && publish_result[:accepted] == true
        end

        def log_reply_publish_failure(publish_result, correlation_id)
          log.warn("[llm][fleet][handler] action=reply_publish_failed correlation_id=#{correlation_id} status=#{publish_result&.[](:status)}")
        end
      end
    end
  end
end
