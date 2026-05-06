# frozen_string_literal: true

require 'json'

require 'legion/extensions/llm/fleet/protocol'

require_relative 'worker_execution'

module Legion
  module LLM
    module Fleet
      # Shared implementation for provider-owned fleet responder runners.
      module ProviderResponder
        class ConfigurationError < StandardError; end

        REQUIRED_FIELDS = %i[
          request_id correlation_id idempotency_key operation provider provider_instance model params reply_to
          message_context caller trace_context signed_token timeout_seconds expires_at protocol_version
        ].freeze
        LEGACY_FIELDS = %i[schema_version request_type fleet_correlation_id].freeze

        FleetEnvelope = Struct.new(:data, keyword_init: true) do
          def [](key)
            data[key.to_sym] || data[key.to_s]
          end

          def key?(key)
            data.key?(key.to_sym) || data.key?(key.to_s)
          end

          def fetch(key, default = nil)
            key?(key) ? self[key] : default
          end

          def to_h
            data
          end

          def protocol_version = self[:protocol_version]
          def request_id = self[:request_id]
          def correlation_id = self[:correlation_id]
          def idempotency_key = self[:idempotency_key]
          def operation = self[:operation]
          def provider = self[:provider]
          def provider_instance = self[:provider_instance]
          def model = self[:model]
          def params = self[:params] || {}
          def reply_to = self[:reply_to]
          def message_context = self[:message_context] || {}
          def trace_context = self[:trace_context] || {}
        end

        module_function

        def call(payload:, provider_family:, provider_class:, provider_instances:, delivery: nil, properties: nil)
          ensure_worker_execution!
          envelope = parse_payload(payload)
          validate_envelope!(envelope, provider_family:)
          provider = build_provider(envelope:, provider_class:, provider_instances:)
          response = WorkerExecution.call(envelope: envelope, provider: provider)
          publish_response(envelope, response)
          ack(delivery || properties)
          response
        rescue StandardError => e
          publish_error(envelope, e) if defined?(envelope) && envelope
          reject(delivery || properties, requeue: requeue_error?(e))
          raise
        end

        def enabled_for?(provider_instances)
          instances = resolve_provider_instances(provider_instances)
          instances.any? do |_instance_id, settings|
            truthy?(dig(settings, :fleet, :respond_to_requests))
          end
        end

        def parse_payload(payload)
          hash = case payload
                 when FleetEnvelope
                   payload.to_h
                 when String
                   parse_json(payload)
                 else
                   payload.respond_to?(:to_h) ? payload.to_h : {}
                 end
          FleetEnvelope.new(data: deep_symbolize(hash))
        end

        def validate_envelope!(envelope, provider_family:)
          reject_legacy_fields!(envelope)
          REQUIRED_FIELDS.each do |field|
            raise ArgumentError, "#{field} is required" unless envelope.key?(field) && !envelope[field].nil?
          end

          validate_protocol_version!(envelope)
          validate_provider_family!(envelope, provider_family)
          true
        end

        def build_provider(envelope:, provider_class:, provider_instances:)
          instances = resolve_provider_instances(provider_instances)
          instance_id = envelope.provider_instance.to_s
          instance_settings = instances[instance_id.to_sym] || instances[instance_id]
          raise ConfigurationError, "fleet provider instance is not configured: #{instance_id}" unless instance_settings
          unless truthy?(dig(instance_settings, :fleet, :respond_to_requests))
            raise ConfigurationError, "fleet responses are disabled for provider instance: #{instance_id}"
          end

          provider_class.new(deep_symbolize(instance_settings))
        end

        def publish_response(envelope, response)
          require 'legion/extensions/llm/transport/messages/fleet_response'

          ::Legion::Extensions::Llm::Transport::Messages::FleetResponse.new(
            protocol_version:  envelope.protocol_version,
            request_id:        envelope.request_id,
            correlation_id:    envelope.correlation_id,
            idempotency_key:   envelope.idempotency_key,
            operation:         envelope.operation,
            provider:          envelope.provider,
            provider_instance: envelope.provider_instance,
            model:             envelope.model,
            reply_to:          envelope.reply_to,
            message_context:   envelope.message_context,
            trace_context:     envelope.trace_context,
            content:           response_content(response),
            tool_calls:        response_field(response, :tool_calls) || [],
            usage:             response_usage(response),
            finish_reason:     response_field(response, :finish_reason),
            metadata:          response_metadata(response)
          ).publish
        end

        def publish_error(envelope, error)
          require 'legion/extensions/llm/transport/messages/fleet_error'

          ::Legion::Extensions::Llm::Transport::Messages::FleetError.new(
            protocol_version:  envelope.protocol_version,
            request_id:        envelope.request_id,
            correlation_id:    envelope.correlation_id,
            idempotency_key:   envelope.idempotency_key,
            operation:         envelope.operation,
            provider:          envelope.provider,
            provider_instance: envelope.provider_instance,
            model:             envelope.model,
            reply_to:          envelope.reply_to,
            message_context:   envelope.message_context,
            trace_context:     envelope.trace_context,
            code:              error_code(error),
            message:           error.message,
            error_class:       error.class.name,
            retryable:         retryable_error?(error),
            metadata:          {}
          ).publish
        end

        def ack(delivery)
          return unless delivery

          if delivery.respond_to?(:ack)
            delivery.ack
          elsif delivery.respond_to?(:channel) && delivery.respond_to?(:delivery_tag)
            delivery.channel.ack(delivery.delivery_tag)
          end
        end

        def reject(delivery, requeue:)
          return unless delivery

          if delivery.respond_to?(:reject)
            delivery.reject(requeue)
          elsif delivery.respond_to?(:channel) && delivery.respond_to?(:delivery_tag)
            delivery.channel.reject(delivery.delivery_tag, requeue)
          end
        end

        def ensure_worker_execution!
          return if defined?(WorkerExecution) && WorkerExecution.respond_to?(:call)

          raise ConfigurationError, 'Legion::LLM::Fleet::WorkerExecution is required for fleet responders'
        end

        def parse_json(payload)
          if defined?(Legion::JSON)
            Legion::JSON.parse(payload)
          else
            ::JSON.parse(payload)
          end
        end

        def reject_legacy_fields!(envelope)
          LEGACY_FIELDS.each do |field|
            raise ArgumentError, "#{field} is not supported by fleet protocol v2" if envelope.key?(field)
          end
        end

        def validate_protocol_version!(envelope)
          return if envelope.protocol_version == ::Legion::Extensions::Llm::Fleet::Protocol::VERSION

          raise ArgumentError, "protocol_version must be #{::Legion::Extensions::Llm::Fleet::Protocol::VERSION}"
        end

        def validate_provider_family!(envelope, provider_family)
          return if envelope.provider.to_s == provider_family.to_s

          raise ArgumentError, "fleet request provider #{envelope.provider} does not match #{provider_family}"
        end

        def resolve_provider_instances(provider_instances)
          instances = provider_instances.respond_to?(:call) ? provider_instances.call : provider_instances
          deep_symbolize(instances || {})
        end

        def requeue_error?(error)
          retryable_error?(error) &&
            Legion::LLM::Settings.value(:fleet, :consumer, :requeue_transient, default: true) != false
        end

        def retryable_error?(error)
          return false if error.is_a?(ConfigurationError)
          return false if defined?(WorkerExecution::PolicyError) && error.is_a?(WorkerExecution::PolicyError)

          true
        end

        def error_code(error)
          return 'configuration_error' if error.is_a?(ConfigurationError)
          return 'policy_error' if defined?(WorkerExecution::PolicyError) && error.is_a?(WorkerExecution::PolicyError)

          'provider_error'
        end

        def response_content(response)
          response_field(response, :content) || response_field(response, :result) || response.to_s
        end

        def response_usage(response)
          usage = response_field(response, :usage) || response_field(response, :tokens)
          return deep_symbolize(usage) if usage.respond_to?(:to_h)

          {
            input_tokens:    response_field(response, :input_tokens),
            output_tokens:   response_field(response, :output_tokens),
            thinking_tokens: response_field(response, :thinking_tokens)
          }.compact
        end

        def response_metadata(response)
          metadata = response_field(response, :metadata)
          metadata.respond_to?(:to_h) ? deep_symbolize(metadata) : {}
        end

        def response_field(response, field)
          return response[field] if response.respond_to?(:key?) && response.key?(field)
          return response[field.to_s] if response.respond_to?(:key?) && response.key?(field.to_s)
          return response.public_send(field) if response.respond_to?(field)

          nil
        end

        def dig(hash, *keys)
          keys.reduce(hash) do |current, key|
            break nil unless current.respond_to?(:key?)

            current[key.to_sym] || current[key.to_s]
          end
        end

        def truthy?(value)
          value == true || value.to_s == 'true'
        end

        def deep_symbolize(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, child), result|
              result[key.respond_to?(:to_sym) ? key.to_sym : key] = deep_symbolize(child)
            end
          when Array
            value.map { |child| deep_symbolize(child) }
          else
            value
          end
        end
      end
    end
  end
end
