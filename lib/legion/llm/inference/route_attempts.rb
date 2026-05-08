# frozen_string_literal: true

module Legion
  module LLM
    module Inference
      # Shared executor helpers for direct/fleet provider dispatch attempt metadata.
      module RouteAttempts
        private

        def fleet_dispatch?
          @resolved_tier == :fleet &&
            Legion::LLM::Settings.value(:fleet, :dispatch, :enabled, default: true) != false
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.fleet_dispatch_enabled')
          false
        end

        def dispatch_provider_request(capability:, operation:, messages:, stream_block: nil)
          if fleet_dispatch?
            dispatch_fleet_request(operation: operation, messages: messages, stream_block: stream_block)
          else
            dispatch_direct_request(capability: capability, operation: operation, messages: messages,
                                    stream_block: stream_block)
          end
        end

        def dispatch_direct_request(capability:, operation:, messages:, stream_block: nil)
          idempotency_key = next_route_idempotency_key
          result = Call::Dispatch.call(
            provider:   @resolved_provider,
            instance:   @resolved_instance,
            capability: capability,
            model:      @resolved_model,
            messages:   messages,
            **native_dispatch_options,
            &stream_block
          )
          record_route_attempt(
            dispatch_path:   :direct,
            operation:       operation,
            status:          :success,
            idempotency_key: idempotency_key,
            selected_lane:   nil
          )
          result
        rescue StandardError => e
          record_route_attempt(
            dispatch_path:   :direct,
            operation:       operation,
            status:          :failure,
            idempotency_key: idempotency_key,
            selected_lane:   nil,
            failure_reason:  e.message
          )
          raise
        end

        def dispatch_fleet_request(operation:, messages:, stream_block: nil)
          idempotency_key = next_route_idempotency_key
          selected_lane = fleet_selected_lane(operation)
          result = Fleet::Dispatcher.dispatch(
            operation:       operation,
            routing_key:     selected_lane,
            message_context: fleet_message_context,
            request:         fleet_dispatch_request(messages, idempotency_key)
          )
          if result[:success] == false || result['success'] == false
            failure_reason = result[:error] || result['error'] || 'fleet_error'
            record_route_attempt(
              dispatch_path:   :fleet,
              operation:       operation,
              status:          :failure,
              idempotency_key: idempotency_key,
              selected_lane:   selected_lane,
              failure_reason:  failure_reason
            )
            raise Legion::LLM::ProviderError, failure_reason.to_s
          end

          normalized = normalize_fleet_result(result)
          stream_block&.call(normalized[:result]) if stream_block && normalized[:result]
          record_route_attempt(
            dispatch_path:   :fleet,
            operation:       operation,
            status:          :success,
            idempotency_key: idempotency_key,
            selected_lane:   selected_lane
          )
          normalized
        end

        def fleet_dispatch_request(messages, idempotency_key)
          {
            provider:          @resolved_provider,
            provider_instance: @resolved_instance || :default,
            model:             @resolved_model,
            idempotency_key:   idempotency_key,
            messages:          messages,
            caller:            @request.caller,
            trace_context:     @tracing || {},
            timeout:           @request.ttl
          }.merge(native_dispatch_options).compact
        end

        def normalize_fleet_result(result)
          normalized = if result.respond_to?(:transform_keys)
                         result.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                       else
                         {}
                       end
          content = normalized[:content] || normalized[:result] || normalized[:data]
          {
            result:      content,
            model:       normalized[:model] || @resolved_model,
            usage:       normalized[:usage] || {},
            tool_calls:  normalized[:tool_calls],
            stop_reason: normalized[:finish_reason] || normalized[:stop_reason],
            thinking:    normalized[:thinking],
            metadata:    normalized[:metadata] || {}
          }.compact
        end

        def fleet_selected_lane(operation)
          @resolved_offering_metadata[:fleet_lane] ||
            @resolved_offering_metadata['fleet_lane'] ||
            @resolved_offering_metadata[:fleet_offering_lane] ||
            @resolved_offering_metadata['fleet_offering_lane'] ||
            Fleet::Lane.routing_key(
              operation:      operation,
              model:          @resolved_model,
              context_window: fleet_context_window
            )
        end

        def fleet_context_window
          limits = @resolved_offering_metadata[:limits] || @resolved_offering_metadata['limits'] || {}
          limits = normalize_offering_metadata(limits) if limits.is_a?(Hash)
          @resolved_offering_metadata[:context_window] ||
            @resolved_offering_metadata['context_window'] ||
            limits[:context_window]
        end

        def fleet_message_context
          {
            request_id:      @request.id,
            conversation_id: @request.conversation_id
          }.compact
        end

        def next_route_idempotency_key
          @request.idempotency_key || "idem_#{SecureRandom.uuid}"
        end

        def record_route_attempt(dispatch_path:, operation:, status:, idempotency_key:, selected_lane:, failure_reason: nil)
          attempt = {
            provider:          @resolved_provider,
            provider_instance: @resolved_instance || :default,
            model:             @resolved_model,
            offering_id:       @resolved_offering_id,
            operation:         operation,
            dispatch_path:     dispatch_path,
            status:            status,
            idempotency_key:   idempotency_key,
            failure_reason:    failure_reason,
            escalation:        @current_escalation_context
          }.compact
          attempt[:selected_lane] = selected_lane
          @route_attempts << attempt
          @timeline.record(
            category:    :provider,
            key:         'provider:route_attempt',
            exchange_id: @exchange_id,
            direction:   :internal,
            detail:      "#{dispatch_path} #{operation} #{status}",
            from:        'pipeline',
            to:          "provider:#{@resolved_provider}",
            data:        attempt
          )
          attempt
        end
      end
    end
  end
end
