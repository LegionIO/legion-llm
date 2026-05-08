# frozen_string_literal: true

require 'securerandom'
require 'time'

require 'legion/extensions/llm/fleet/protocol'
require 'legion/logging/helper'

require_relative '../publisher_identity'
require_relative 'token_issuer'

module Legion
  module LLM
    module Fleet
      module Dispatcher
        extend Legion::Logging::Helper

        ENVELOPE_KEYS = %i[
          app_id caller correlation_id expires_at idempotency_key identity message_context operation
          model priority protocol_version provider provider_instance reply_to request_id routing_key
          signed_token timeout timeout_seconds trace_context ttl
        ].freeze
        LEGACY_FIELDS = %i[schema_version request_type fleet_correlation_id].freeze

        module_function

        def dispatch(operation: nil, request: nil, message_context: {}, routing_key: nil, reply_to: nil, **opts)
          operation = normalize_operation(operation || fetch_option(request, :operation) || opts[:operation])
          raise ArgumentError, 'operation is required for fleet dispatch' unless operation

          request_opts = normalize_request(request).merge(opts)
          log.debug "[llm][fleet][dispatcher] action=dispatch.enter operation=#{operation} " \
                    "model=#{fetch_option(request_opts, :model)} routing_key=#{routing_key} fleet_available=#{fleet_available?}"
          return error_result('fleet_unavailable', message_context: message_context) unless fleet_available?

          envelope = build_envelope(
            operation:       operation,
            request_opts:    request_opts,
            message_context: message_context,
            routing_key:     routing_key,
            reply_to:        reply_to
          )
          future = register_response(envelope[:correlation_id], expected_delivery(envelope))
          publish_result = publish_request(**envelope)
          unless publish_accepted?(publish_result)
            return publish_error_result(publish_result, envelope[:correlation_id],
                                        message_context: message_context)
          end

          wait_for_response(
            envelope[:correlation_id],
            timeout:         envelope[:timeout_seconds],
            message_context: message_context,
            future:          future
          )
        end

        def build_envelope(operation:, request_opts:, message_context:, routing_key: nil, reply_to: nil)
          provider = fetch_option(request_opts, :provider) || 'ollama'
          reject_legacy_fields!(request_opts)
          provider_instance = fetch_option(request_opts, :provider_instance) ||
                              fetch_option(request_opts, :instance) || 'default'
          model = fetch_option(request_opts, :model)
          timeout = resolve_timeout(operation: operation, override: fetch_option(request_opts, :timeout))
          request_id = next_request_id
          correlation_id = next_request_id
          reply_to ||= ReplyDispatcher.agent_queue_name
          routing_key ||= build_routing_key(
            provider:                provider,
            operation:               operation,
            model:                   model,
            provider_instance:       provider_instance,
            context_window:          context_window_from(request_opts),
            boundary:                fetch_option(request_opts, :network_boundary),
            eligibility_fingerprint: fetch_option(request_opts, :eligibility_fingerprint),
            routing_style:           fetch_option(request_opts, :routing_style)
          )

          envelope = {
            protocol_version:  ::Legion::Extensions::Llm::Fleet::Protocol::VERSION,
            request_id:        request_id,
            correlation_id:    correlation_id,
            idempotency_key:   fetch_option(request_opts, :idempotency_key) || "idem_#{SecureRandom.uuid}",
            operation:         operation,
            provider:          provider,
            provider_instance: provider_instance,
            model:             model,
            params:            request_params(request_opts),
            routing_key:       routing_key,
            reply_to:          reply_to,
            message_context:   message_context || {},
            caller:            fetch_option(request_opts, :caller) || default_caller,
            identity:          Legion::LLM::PublisherIdentity.current,
            trace_context:     fetch_option(request_opts, :trace_context) || {},
            timeout_seconds:   timeout,
            expires_at:        (Time.now.utc + timeout).iso8601,
            ttl:               effective_ttl(request_opts, timeout)
          }
          envelope[:signed_token] = dispatch_auth_required? ? TokenIssuer.issue(envelope) : 'unsigned'
          envelope
        end

        def expected_delivery(envelope)
          {
            protocol_version: envelope[:protocol_version],
            operation:        envelope[:operation],
            correlation_id:   envelope[:correlation_id]
          }
        end

        def build_routing_key(provider:, operation:, model:, provider_instance: nil, context_window: nil, boundary: nil,
                              eligibility_fingerprint: nil, routing_style: nil)
          style = routing_style || default_routing_style
          return Lane.offering_key(instance_id: provider_instance || provider, model: model, operation: operation) if style.to_s == 'offering_lane'

          if style.to_s == 'shared_lane'
            return Lane.routing_key(operation: operation, model: model, context_window: context_window,
                                    boundary: boundary, eligibility_fingerprint: eligibility_fingerprint)
          end

          "llm.request.#{provider}.#{operation}.#{sanitize_model(model)}"
        end

        def default_routing_style
          Legion::LLM::Settings.value(:fleet, :dispatch, :routing_style) ||
            Legion::LLM::Settings.value(:routing, :tiers, :fleet, :routing_style) ||
            :shared_lane
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.dispatcher.default_routing_style')
          :shared_lane
        end

        def context_window_from(options)
          limits = fetch_option(options, :limits) || {}
          fetch_option(options, :context_window) ||
            fetch_option(options, :max_context_size) ||
            fetch_option(options, :max_input_tokens) ||
            fetch_option(limits, :context_window)
        end

        def effective_ttl(options, timeout)
          ttl = fetch_option(options, :ttl)
          return ttl if ttl

          fetch_option(options, :expiration_seconds) || timeout
        end

        def reject_legacy_fields!(request_opts)
          LEGACY_FIELDS.each do |field|
            raise ArgumentError, "#{field} is not supported by fleet protocol v2" if legacy_field_present?(request_opts, field)
          end
        end

        def legacy_field_present?(hash, key)
          return false unless hash.respond_to?(:key?)

          hash.key?(key) || hash.key?(key.to_s)
        end

        def request_params(request_opts)
          normalize_request(request_opts).except(*ENVELOPE_KEYS)
        end

        def normalize_request(request)
          return {} unless request.respond_to?(:to_h)

          request.to_h.transform_keys do |key|
            key.respond_to?(:to_sym) ? key.to_sym : key
          end
        end

        def fetch_option(hash, key)
          return nil unless hash.respond_to?(:key?)

          string_key = key.to_s
          return hash[string_key] if hash.key?(string_key)

          hash[key] if hash.key?(key)
        end

        def sanitize_model(model)
          model.to_s.gsub(':', '.')
        end

        def fleet_available?
          transport_ready? && fleet_enabled?
        end

        def transport_ready?
          Legion::LLM::Settings.transport_connected?
        end

        def fleet_enabled?
          Legion::LLM::Settings.value(:fleet, :dispatch, :enabled, default: true) != false
        end

        def resolve_timeout(operation: :default, request_type: nil, override: nil)
          return override if override

          op = (operation || request_type || :default).to_sym
          timeouts = Legion::LLM::Settings.value(:fleet, :dispatch, :timeouts, default: {}) || {}
          fetch_option(timeouts, op) ||
            Legion::LLM::Settings.value(:fleet, :dispatch, :timeout_seconds, default: 30) ||
            30
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.dispatcher.resolve_timeout')
          30
        end

        def next_request_id
          "req_#{SecureRandom.uuid}"
        end

        def register_response(correlation_id, expected = {})
          ReplyDispatcher.register(correlation_id, expected: expected)
        end

        def publish_request(**opts)
          log.debug("[llm][fleet][dispatcher] action=publish_request correlation_id=#{opts[:correlation_id]} routing_key=#{opts[:routing_key]}")
          require 'legion/extensions/llm/transport/messages/fleet_request'
          ::Legion::Extensions::Llm::Transport::Messages::FleetRequest.new(**opts).publish(request_publish_options)
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.dispatcher.publish_request')
          { accepted: false, status: :failed, error: e.message }
        end

        def publish_accepted?(publish_result)
          publish_result.is_a?(Hash) && publish_result[:accepted] == true
        end

        def request_publish_options
          {
            mandatory:                  Legion::LLM::Settings.value(:fleet, :dispatch, :mandatory, default: true),
            publisher_confirm:          Legion::LLM::Settings.value(:fleet, :dispatch, :publisher_confirm, default: true),
            publish_confirm_timeout_ms: Legion::LLM::Settings.value(:fleet, :dispatch, :publish_confirm_timeout_ms, default: 500),
            spool:                      Legion::LLM::Settings.value(:fleet, :dispatch, :spool, default: false),
            return_result:              true
          }
        end

        def publish_error_result(publish_result, correlation_id, message_context: {})
          ReplyDispatcher.deregister(correlation_id)
          status = publish_result.is_a?(Hash) ? publish_result[:status]&.to_sym : :failed
          error = case status
                  when :unroutable
                    'no_fleet_queue'
                  when :nacked
                    'fleet_backpressure'
                  when :confirm_timeout
                    'fleet_publish_timeout'
                  else
                    'fleet_publish_failed'
                  end
          {
            success:         false,
            error:           error,
            publish_status:  status,
            correlation_id:  correlation_id,
            message_context: message_context
          }
        end

        def wait_for_response(correlation_id, timeout:, message_context: {}, future: nil)
          log.debug "[llm][fleet][dispatcher] action=wait_for_response correlation_id=#{correlation_id} timeout=#{timeout}"
          future ||= ReplyDispatcher.register(correlation_id)
          result = future.value!(timeout)
          result || timeout_result(correlation_id, timeout, message_context: message_context)
        rescue Concurrent::CancelledOperationError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.fleet.dispatcher.wait_cancelled')
          timeout_result(correlation_id, timeout, message_context: message_context)
        ensure
          ReplyDispatcher.deregister(correlation_id)
        end

        def timeout_result(correlation_id, timeout, message_context: {})
          { success: false, error: 'fleet_timeout', correlation_id: correlation_id,
            timeout: timeout, message_context: message_context }
        end

        def error_result(reason, message_context: {})
          { success: false, error: reason, message_context: message_context }
        end

        def normalize_operation(operation)
          return nil if operation.to_s.empty?

          operation.to_sym
        end

        def dispatch_auth_required?
          value = Legion::LLM::Settings.value(:fleet, :dispatch, :require_auth, default: nil)
          return value != false unless value.nil?

          Legion::LLM::Settings.value(:fleet, :auth, :require_signed_token, default: true) != false
        end

        def default_caller
          {
            source:       'legion-llm',
            component:    'fleet_dispatcher',
            requested_by: Legion::LLM::PublisherIdentity.requested_by
          }
        end
      end
    end
  end
end
