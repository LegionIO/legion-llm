# frozen_string_literal: true

module Legion
  module LLM
    module Fleet
      module Dispatcher
        DEFAULT_TIMEOUT = 30

        module_function

        def dispatch(model:, messages:, **opts)
          return error_result('fleet_unavailable') unless fleet_available?

          correlation_id = "fleet_#{SecureRandom.hex(12)}"
          publish_request(model: model, messages: messages, intent: opts[:intent],
                          correlation_id: correlation_id, **opts.except(:intent, :timeout))

          wait_for_response(correlation_id, timeout: resolve_timeout(opts[:timeout]))
        end

        def fleet_available?
          transport_ready? && fleet_enabled?
        end

        def transport_ready?
          !!(defined?(Legion::Transport) &&
             Legion::Transport.respond_to?(:connected?) &&
             Legion::Transport.connected?)
        end

        def fleet_enabled?
          return true unless defined?(Legion::Settings)

          settings = begin
            Legion::Settings[:llm]
          rescue StandardError
            nil
          end
          return true unless settings.is_a?(Hash)

          routing = settings[:routing]
          return true unless routing.is_a?(Hash)

          routing.fetch(:use_fleet, true)
        end

        def resolve_timeout(override)
          return override if override

          return DEFAULT_TIMEOUT unless defined?(Legion::Settings)

          settings = begin
            Legion::Settings[:llm]
          rescue StandardError
            nil
          end
          return DEFAULT_TIMEOUT unless settings.is_a?(Hash)

          settings.dig(:routing, :fleet, :timeout_seconds) || DEFAULT_TIMEOUT
        end

        def publish_request(**)
          return unless defined?(Legion::Extensions::LLM::Gateway::Transport::Messages::InferenceRequest)

          Legion::Extensions::LLM::Gateway::Transport::Messages::InferenceRequest.new(
            reply_to: ReplyDispatcher.agent_queue_name, **
          ).publish
        end

        def wait_for_response(correlation_id, timeout:)
          future = ReplyDispatcher.register(correlation_id)
          result = future.value!(timeout)
          result || timeout_result(correlation_id, timeout)
        rescue Concurrent::CancelledOperationError
          timeout_result(correlation_id, timeout)
        ensure
          ReplyDispatcher.deregister(correlation_id)
        end

        def timeout_result(correlation_id, timeout)
          { success: false, error: 'fleet_timeout', correlation_id: correlation_id, timeout: timeout }
        end

        def error_result(reason)
          { success: false, error: reason }
        end
      end
    end
  end
end
