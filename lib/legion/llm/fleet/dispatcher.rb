# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Fleet
      module Dispatcher
        extend Legion::Logging::Helper

        module_function

        # Backwards-compatible shim: supports old (model:, messages:) and new (request:, message_context:) callers
        def dispatch(model: nil, messages: nil, request: nil, message_context: {}, routing_key: nil, reply_to: nil, **opts)
          log.debug "[llm][fleet][dispatcher] action=dispatch.enter model=#{model} routing_key=#{routing_key} fleet_available=#{fleet_available?}"
          return error_result('fleet_unavailable', message_context: message_context) unless fleet_available?

          # Old calling convention: build minimal params from model/messages
          if request.nil? && (model || messages)
            provider = opts[:provider] || 'ollama'
            request_type = opts[:request_type] || 'chat'
            routing_key ||= build_routing_key(provider: provider, request_type: request_type, model: model,
                                              provider_instance: opts[:provider_instance],
                                              context_window: context_window_from(opts),
                                              boundary: opts[:network_boundary],
                                              eligibility_fingerprint: opts[:eligibility_fingerprint],
                                              routing_style: opts[:routing_style])
            reply_to ||= ReplyDispatcher.agent_queue_name
            correlation_id = next_correlation_id
            future = register_response(correlation_id)
            timeout = resolve_timeout(request_type: request_type, override: opts[:timeout])
            publish_opts = opts.except(:timeout).merge(ttl: effective_ttl(opts, timeout))
            publish_result = publish_request(
              correlation_id: correlation_id,
              routing_key: routing_key, reply_to: reply_to,
              provider: provider, model: model, request_type: request_type,
              messages: messages, message_context: message_context, **publish_opts
            )
            return publish_error_result(publish_result, correlation_id, message_context: message_context) unless publish_accepted?(publish_result)

            return wait_for_response(correlation_id, timeout: timeout, message_context: message_context, future: future)
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
          routing_key ||= build_routing_key(provider: provider, request_type: request_type, model: model,
                                            provider_instance: request_opts[:provider_instance],
                                            context_window: context_window_from(request_opts),
                                            boundary: request_opts[:network_boundary],
                                            eligibility_fingerprint: request_opts[:eligibility_fingerprint],
                                            routing_style: request_opts[:routing_style] || opts[:routing_style])
          reply_to ||= ReplyDispatcher.agent_queue_name
          correlation_id = next_correlation_id
          future = register_response(correlation_id)
          timeout = resolve_timeout(request_type: request_type, override: request_opts[:timeout] || opts[:timeout])
          request_opts[:ttl] = effective_ttl(request_opts, timeout)
          publish_result = publish_request(
            correlation_id: correlation_id,
            routing_key: routing_key, reply_to: reply_to,
            provider: provider, model: model, request_type: request_type,
            message_context: message_context, **request_opts.except(:provider, :model, :request_type, :timeout)
          )
          return publish_error_result(publish_result, correlation_id, message_context: message_context) unless publish_accepted?(publish_result)

          wait_for_response(correlation_id, timeout: timeout, message_context: message_context, future: future)
        end

        def build_routing_key(provider:, request_type:, model:, provider_instance: nil, context_window: nil, boundary: nil,
                              eligibility_fingerprint: nil, routing_style: nil)
          style = routing_style || default_routing_style
          return Lane.offering_key(instance_id: provider_instance || provider, model: model, operation: request_type) if style.to_s == 'offering_lane'

          if style.to_s == 'shared_lane'
            return Lane.routing_key(operation: request_type, model: model, context_window: context_window,
                                    boundary: boundary, eligibility_fingerprint: eligibility_fingerprint)
          end

          "llm.request.#{provider}.#{request_type}.#{sanitize_model(model)}"
        end

        def default_routing_style
          Legion::LLM::Settings.value(:routing, :tiers, :fleet, :routing_style) ||
            Legion::LLM::Settings.value(:routing, :fleet, :routing_style) ||
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
          fetch_option(options, :ttl) || fetch_option(options, :expiration_seconds) || timeout
        end

        def fetch_option(hash, key)
          return nil unless hash.respond_to?(:key?)

          string_key = key.to_s
          return hash[string_key] if hash.key?(string_key)

          hash[key] if hash.key?(key)
        end

        def nested_fetch(hash, *keys)
          keys.reduce(hash) do |current, key|
            return nil unless current.respond_to?(:key?)

            fetch_option(current, key)
          end
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
          routing = Legion::LLM::Settings.value(:routing, default: {})
          return true unless routing.is_a?(Hash)

          fetch_option(routing, :use_fleet) != false
        end

        def resolve_timeout(request_type: :default, override: nil)
          return override if override

          fleet = Legion::LLM::Settings.value(:routing, :tiers, :fleet) ||
                  Legion::LLM::Settings.value(:routing, :fleet) ||
                  {}
          timeouts = fetch_option(fleet, :timeouts) || {}
          fetch_option(timeouts, request_type.to_sym) || fetch_option(fleet, :timeout_seconds) || 30
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.dispatcher.resolve_timeout')
          30
        end

        def next_correlation_id
          "req_#{SecureRandom.uuid}"
        end

        def register_response(correlation_id, expected = {})
          ReplyDispatcher.register(correlation_id, expected: expected)
        end

        def publish_request(correlation_id: next_correlation_id, **opts)
          opts[:fleet_correlation_id] = correlation_id
          log.debug("[llm][fleet][dispatcher] action=publish_request correlation_id=#{correlation_id} routing_key=#{opts[:routing_key]}")

          if defined?(Legion::LLM::Transport::Messages::FleetRequest)
            Legion::LLM::Transport::Messages::FleetRequest.new(**opts).publish
          else
            log.debug('[llm][fleet][dispatcher] action=skip_publish reason=transport_not_loaded')
            { accepted: false, status: :failed, error: 'transport_not_loaded' }
          end
        end

        def publish_accepted?(publish_result)
          publish_result.is_a?(Hash) ? publish_result[:accepted] == true : true
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
