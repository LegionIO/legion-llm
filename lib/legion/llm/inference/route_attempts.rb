# frozen_string_literal: true

module Legion
  module LLM
    module Inference
      # Shared executor helpers for direct/fleet provider dispatch attempt metadata.
      module RouteAttempts
        private

        def fleet_dispatch?
          @resolved_tier == :fleet && Legion::Settings[:llm][:fleet][:dispatch][:enabled] != false
        end

        def dispatch_provider_request(capability:, operation:, messages:, stream_block: nil)
          if fleet_dispatch?
            log.debug "[llm][route_attempts] action=dispatch path=fleet provider=#{@resolved_provider} model=#{@resolved_model} operation=#{operation}"
            dispatch_fleet_request(operation: operation, messages: messages, stream_block: stream_block)
          else
            log.debug "[llm][route_attempts] action=dispatch path=direct provider=#{@resolved_provider} model=#{@resolved_model} operation=#{operation}"
            dispatch_direct_request(capability: capability, operation: operation, messages: messages,
                                    stream_block: stream_block)
          end
        end

        # REMOVED: dispatch_responses_request
        # N×N LAW: all dispatch goes through dispatch_provider_request(capability: :chat/:stream).
        # The capability :responses capability is a provider wire-format detail — the canonical
        # core only knows :chat and :stream. See lex-llm-* adapters for wire-format decisions.

        def dispatch_direct_request(capability:, operation:, messages:, stream_block: nil)
          idempotency_key = next_route_idempotency_key
          dispatch_options = native_dispatch_options
          enforce_final_context_budget!(messages, dispatch_options)
          result = Legion::LLM::Call::Dispatch.call(
            provider:   @resolved_provider,
            instance:   @resolved_instance,
            capability: capability,
            model:      @resolved_model,
            messages:   messages,
            **dispatch_options,
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
          log.info "[llm][route_attempts] action=fleet_dispatch provider=#{@resolved_provider} model=#{@resolved_model} lane=#{selected_lane} operation=#{operation}"
          result = Fleet::Dispatcher.dispatch(
            operation:       operation,
            routing_key:     selected_lane,
            message_context: fleet_message_context,
            request:         fleet_dispatch_request(messages, idempotency_key)
          )
          if result[:success] == false || result['success'] == false
            failure_reason = result[:error] || result['error'] || 'fleet_error'
            log.warn "[llm][route_attempts] action=fleet_failed provider=#{@resolved_provider} model=#{@resolved_model} lane=#{selected_lane} reason=#{failure_reason}"
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

        def enforce_final_context_budget!(messages, dispatch_options)
          context_window = final_context_window
          return unless context_window.positive?

          threshold = (context_window * 0.90).to_i
          estimated_tokens = final_dispatch_token_estimate(messages, dispatch_options)
          return if estimated_tokens <= threshold

          raise Legion::LLM::ContextOverflow,
                "#{@resolved_provider}:#{@resolved_model} - final payload estimate #{estimated_tokens} " \
                "tokens exceeds dispatch threshold #{threshold} for context window #{context_window}"
        end

        def final_dispatch_token_estimate(messages, dispatch_options)
          estimated = Legion::LLM::Inference::ContextAccounting.estimate_message_tokens(messages)
          estimated += Legion::LLM::Inference::ContextAccounting.estimate_text_tokens(dispatch_options[:system]) if
            dispatch_options[:system]
          estimated += Legion::LLM::Inference::ContextAccounting.estimate_json_tokens(dispatch_options[:tools]) if
            dispatch_options[:tools]
          estimated += Legion::LLM::Inference::ContextAccounting.estimate_json_tokens(dispatch_options[:tool_prefs]) if
            dispatch_options[:tool_prefs]
          estimated += Legion::LLM::Inference::ContextAccounting.estimate_json_tokens(dispatch_options[:thinking]) if
            dispatch_options[:thinking]
          estimated
        end

        def final_context_window
          metadata = @resolved_offering_metadata || {}
          limits = metadata[:limits] || metadata['limits'] || {}
          limits = normalize_offering_metadata(limits) if limits.is_a?(Hash)
          (metadata[:context_window] || metadata['context_window'] || limits[:context_window]).to_i
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
