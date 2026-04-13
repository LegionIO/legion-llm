# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Fleet
      module Dispatcher
        DEFAULT_TIMEOUT = 30

        TIMEOUTS = {
          embed:    10,
          chat:     30,
          generate: 30,
          default:  30
        }.freeze

        extend Legion::Logging::Helper

        module_function

        # Backwards-compatible shim: supports old (model:, messages:) and new (request:, message_context:) callers
        def dispatch(model: nil, messages: nil, request: nil, message_context: {}, routing_key: nil, reply_to: nil, **opts)
          return error_result('fleet_unavailable', message_context: message_context) unless fleet_available?

          # Old calling convention: build minimal params from model/messages
          if request.nil? && (model || messages)
            provider = opts[:provider] || 'ollama'
            request_type = opts[:request_type] || 'chat'
            routing_key ||= build_routing_key(provider: provider, request_type: request_type, model: model)
            reply_to ||= ReplyDispatcher.agent_queue_name
            correlation_id = publish_request(
              routing_key: routing_key, reply_to: reply_to,
              provider: provider, model: model, request_type: request_type,
              messages: messages, message_context: message_context, **opts
            )
            timeout = resolve_timeout(request_type: request_type, override: opts[:timeout])
            return wait_for_response(correlation_id, timeout: timeout, message_context: message_context)
          end

          # New calling convention
          request_opts =
            if request.respond_to?(:to_h)
              request.to_h.transform_keys(&:to_sym)
            else
              {}
            end
          request_opts = request_opts.merge(opts)

          provider = request_opts[:provider] || 'ollama'
          request_type = request_opts[:request_type] || 'chat'
          model = request_opts[:model]
          routing_key ||= build_routing_key(provider: provider, request_type: request_type, model: model)
          reply_to ||= ReplyDispatcher.agent_queue_name
          correlation_id = publish_request(
            routing_key: routing_key, reply_to: reply_to,
            provider: provider, model: model, request_type: request_type,
            message_context: message_context, **request_opts.except(:provider, :model, :request_type, :timeout)
          )
          timeout = resolve_timeout(request_type: request_type, override: request_opts[:timeout] || opts[:timeout])
          wait_for_response(correlation_id, timeout: timeout, message_context: message_context)
        end

        def build_routing_key(provider:, request_type:, model:)
          "llm.request.#{provider}.#{request_type}.#{sanitize_model(model)}"
        end

        def sanitize_model(model)
          model.to_s.gsub(':', '.')
        end

        def fleet_available?
          transport_ready? && fleet_enabled?
        end

        def transport_ready?
          !!(defined?(Legion::Settings) &&
             Legion::Settings[:transport][:connected] == true)
        end

        def fleet_enabled?
          return true unless defined?(Legion::Settings)

          settings = begin
            Legion::Settings[:llm]
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.fleet.dispatcher.fleet_enabled')
            nil
          end
          return true unless settings.is_a?(Hash)

          routing = settings[:routing]
          return true unless routing.is_a?(Hash)

          routing.fetch(:use_fleet, true)
        end

        def resolve_timeout(request_type: :default, override: nil)
          return override if override

          configured = fleet_timeout_from_settings(request_type)
          return configured if configured

          TIMEOUTS[request_type.to_sym] || TIMEOUTS[:default]
        end

        def fleet_timeout_from_settings(request_type)
          return unless defined?(Legion::Settings)

          settings = begin
            Legion::Settings[:llm]
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.fleet.dispatcher.resolve_timeout')
            nil
          end

          return unless settings.is_a?(Hash)

          routing = settings[:routing]
          return unless routing.is_a?(Hash)

          fleet_settings = routing.dig(:tiers, :fleet)
          fleet_settings = routing[:fleet] unless fleet_settings.is_a?(Hash)
          return unless fleet_settings.is_a?(Hash)

          fleet_settings.dig(:timeouts, request_type.to_sym) || fleet_settings[:timeout_seconds]
        end

        def publish_request(**opts)
          correlation_id = "req_#{SecureRandom.uuid}"
          opts[:fleet_correlation_id] = correlation_id

          if defined?(Legion::LLM::Fleet::Request)
            Legion::LLM::Fleet::Request.new(**opts).publish
          elsif defined?(Legion::Extensions::LLM::Gateway::Transport::Messages::InferenceRequest)
            Legion::Extensions::LLM::Gateway::Transport::Messages::InferenceRequest.new(
              reply_to: opts[:reply_to], **opts.except(:reply_to)
            ).publish
          end

          correlation_id
        end

        def wait_for_response(correlation_id, timeout:, message_context: {})
          future = ReplyDispatcher.register(correlation_id)
          result = future.value!(timeout)
          result || timeout_result(correlation_id, timeout, message_context: message_context)
        rescue Concurrent::CancelledOperationError
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
      end
    end
  end
end
