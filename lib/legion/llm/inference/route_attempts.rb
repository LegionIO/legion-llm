# frozen_string_literal: true

require 'legion/extensions/llm/fleet/protocol'
require 'legion/extensions/llm/taxonomies'

module Legion
  module LLM
    module Inference
      # Shared executor helpers for direct/fleet provider dispatch attempt metadata.
      module RouteAttempts
        # N9: :headers was a dead contract key — nothing populates it in the
        # SSOT dispatch path (native_dispatch_options), and per-request caller
        # headers are a transport concern of the calling side, not fleet wire.
        CONTRACT_OPTION_KEYS = %i[tools temperature params schema thinking tool_prefs].freeze
        NONCONTRACT_GENERATION_KEYS = %i[top_p top_k frequency_penalty presence_penalty seed].freeze
        private_constant :CONTRACT_OPTION_KEYS, :NONCONTRACT_GENERATION_KEYS

        private

        def fleet_dispatch?
          @resolved_tier == :fleet && Legion::Settings[:llm][:fleet][:dispatch][:enabled] != false
        end

        def dispatch_provider_request(capability:, operation:, messages:, stream_block: nil)
          raw_options = native_dispatch_options
          dispatch_messages, dispatch_options = if @current_attempt_context
                                                  project_dispatch_arguments(
                                                    messages: messages, options: raw_options
                                                  )
                                                else
                                                  [messages, raw_options]
                                                end
          if fleet_dispatch?
            fleet_operation = ssot_v3_fleet_operation(operation)
            log.debug "[llm][route_attempts] action=dispatch path=fleet provider=#{@resolved_provider} model=#{@resolved_model} operation=#{fleet_operation}"
            dispatch_fleet_request(
              operation: fleet_operation, messages: dispatch_messages,
              dispatch_options: dispatch_options, stream_block: stream_block
            )
          else
            log.debug "[llm][route_attempts] action=dispatch path=direct provider=#{@resolved_provider} model=#{@resolved_model} operation=#{operation}"
            dispatch_direct_request(
              capability: capability, operation: operation, messages: dispatch_messages,
              raw_messages: messages, dispatch_options: dispatch_options,
              raw_dispatch_options: raw_options, stream_block: stream_block
            )
          end
        end

        # REMOVED: dispatch_responses_request
        # N×N LAW: all dispatch goes through dispatch_provider_request(capability: :chat/:stream).
        # The capability :responses capability is a provider wire-format detail — the canonical
        # core only knows :chat and :stream. See lex-llm-* adapters for wire-format decisions.

        def dispatch_direct_request(capability:, operation:, messages:, raw_messages:,
                                    dispatch_options:, raw_dispatch_options:, stream_block: nil)
          idempotency_key = next_route_idempotency_key
          enforce_final_context_budget!(raw_messages, raw_dispatch_options)

          if @current_attempt_context
            return ssot_v3_direct_dispatch(
              operation: operation, messages: messages,
              dispatch_options: dispatch_options, idempotency_key: idempotency_key,
              stream_block: stream_block
            )
          end

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

        # SSOT v3 §15 — dispatch through SelectionDispatch using the AttemptContext
        # set by run_provider_call_ssot_v3_single/stream. On SelectionDispatch success
        # returns the provider value; on failure re-raises as the appropriate Legion
        # error so the existing rescue clauses in run_provider_call_single /
        # step_provider_call_stream continue to work.
        def ssot_v3_direct_dispatch(operation:, messages:, dispatch_options:, idempotency_key:, stream_block:)
          arguments = dispatch_options.merge(messages: messages)
          # §15.2: reuse the streaming preflight lease when present (attempt one on
          # the exact selected callable). After a mid-stream failover the executor
          # has released it (@preflight_lease == nil) and SelectionDispatch acquires
          # its own lease for the re-selected callable.
          sd_result = Legion::LLM::Call::SelectionDispatch.call(
            attempt_context: @current_attempt_context,
            arguments:       arguments,
            dispatch_lease:  @preflight_lease,
            &stream_block
          )
          if sd_result.success?
            record_route_attempt(
              dispatch_path:   :direct,
              operation:       operation,
              status:          :success,
              idempotency_key: idempotency_key,
              selected_lane:   nil
            )
            # Dispatch-boundary contract (pre-SSOT Call::Dispatch.call): the
            # executor consumes a Canonical::Response, never the raw provider
            # value. SelectionDispatch returns the raw callable return (a
            # lex-llm Message for sync/stream chat), so normalize it here —
            # the native tool loop and response translation are written
            # against Canonical::Response.
            return Legion::LLM::Call::Dispatch.normalize_response(sd_result.value)
          end

          record_route_attempt(
            dispatch_path:   :direct,
            operation:       operation,
            status:          :failure,
            idempotency_key: idempotency_key,
            selected_lane:   nil,
            failure_reason:  sd_result.outcome.reason
          )
          # M3.3: the exact Phase 1 outcome rides ON the raised error (no
          # side-channel ivar) — the streaming failover classifier (§19) and the
          # sync rescue path both read the typed kind off the error itself.
          raise ssot_v3_provider_outcome_error(sd_result.outcome)
        end

        # M3.3: one authoritative outcome. The Legion error preserves its class
        # for the existing rescue logic AND carries the exact typed
        # ProviderOutcome so no consumer loses the normalized kind.
        def ssot_v3_provider_outcome_error(outcome)
          case outcome.kind
          when :overloaded, :rate_limited
            Legion::LLM::ProviderError.new("provider #{outcome.kind}: #{outcome.reason}", outcome: outcome)
          when :authentication, :authorization
            Legion::LLM::AuthError.new(outcome.reason, outcome: outcome)
          else
            Legion::LLM::ProviderError.new("provider error #{outcome.kind}: #{outcome.reason}", outcome: outcome)
          end
        end

        def dispatch_fleet_request(operation:, messages:, dispatch_options:, stream_block: nil)
          validate_ssot_v3_fleet_operation!(operation)
          idempotency_key = next_route_idempotency_key
          selected_lane = fleet_selected_lane(operation)
          log.info "[llm][route_attempts] action=fleet_dispatch provider=#{@resolved_provider} model=#{@resolved_model} lane=#{selected_lane} operation=#{operation}"
          result = Fleet::Dispatcher.dispatch(
            operation:       operation,
            routing_key:     selected_lane,
            message_context: fleet_message_context,
            request:         fleet_dispatch_request(
              messages, idempotency_key, dispatch_options: dispatch_options
            )
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

          response = normalize_fleet_result(result)
          stream_fleet_response(stream_block, response) if stream_block
          record_route_attempt(
            dispatch_path:   :fleet,
            operation:       operation,
            status:          :success,
            idempotency_key: idempotency_key,
            selected_lane:   selected_lane
          )
          response
        end

        # The v3 worker returns one collected Canonical::Response per fleet
        # request (no per-chunk wire). Surface it to the client stream as the
        # canonical chunk pair the assembler already consumes: a text delta
        # (when there is text) followed by the done chunk with usage and
        # stop_reason.
        def stream_fleet_response(stream_block, response)
          request_id = @request.id
          unless response.text.to_s.empty?
            stream_block.call(Legion::Extensions::Llm::Canonical::Chunk.text_delta(
                                delta: response.text, request_id: request_id, block_index: 0
                              ))
          end
          stream_block.call(Legion::Extensions::Llm::Canonical::Chunk.done(
                              request_id: request_id, usage: response.usage, stop_reason: response.stop_reason
                            ))
        end

        # Coarse-lane-type comparison, mirroring the lex-llm fleet worker's
        # require_matching_operation!: the operation is a request property, the
        # lane constrains type/model/instance — the lane's operation member is
        # its type's representative, not the identity.
        def ssot_v3_fleet_operation(requested_operation)
          return requested_operation unless @current_attempt_context

          selection_operation = @current_attempt_context.selection.operation
          lane_operation = @current_attempt_context.lane.operation
          unless Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: selection_operation) ==
                 Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: lane_operation)
            raise ArgumentError,
                  "SSOT fleet selection/lane operation mismatch: #{selection_operation.inspect} != #{lane_operation.inspect}"
          end

          selection_operation
        end

        def validate_ssot_v3_fleet_operation!(operation)
          return unless @current_attempt_context

          selection_operation = @current_attempt_context.selection.operation
          return if Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: operation) ==
                    Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: selection_operation)

          raise ArgumentError,
                "SSOT fleet envelope operation mismatch: #{operation.inspect} != " \
                "#{selection_operation.inspect}"
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

        def fleet_dispatch_request(messages, idempotency_key, dispatch_options:)
          {
            provider:          @resolved_provider,
            # L10: no synthesized identity — the Selection-derived instance is
            # authoritative. A missing instance is a routing fault: the
            # dispatcher's exact-value check raises, it never executes as
            # :default.
            provider_instance: @resolved_instance,
            model:             @resolved_model,
            idempotency_key:   idempotency_key,
            # The wire carries serialized Canonical::Message (the worker's
            # rehydrate_wire_messages is the rehydration boundary). L10:
            # canonicalize at the boundary exactly as the direct path does —
            # no non-canonical element passes through unraised.
            messages:          Legion::LLM::Inference::Request.canonicalize_messages(messages).map(&:to_h),
            caller:            @request.caller,
            trace_context:     @tracing || {},
            timeout:           @request.ttl
          }.merge(dispatch_options).merge(exact_execution_envelope_fields).compact
        end

        def exact_execution_envelope_fields
          return {} unless @current_attempt_context

          raise ArgumentError, 'SSOT fleet dispatch requires a nonempty String resolved offering_id' unless @resolved_offering_id.is_a?(String) && !@resolved_offering_id.strip.empty?

          {
            execution_contract: ::Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
            offering_id:        @resolved_offering_id
          }
        end

        def project_dispatch_arguments(messages:, options:)
          system_text = options[:system].to_s
          # SSOT dispatch boundary: every SSOT message is canonical before it
          # reaches either dispatch branch (direct callable or fleet wire).
          canonical_messages = Legion::LLM::Inference::Request.canonicalize_messages(messages)
          folded = if system_text.strip.empty?
                     canonical_messages
                   else
                     fold_system_into_messages(messages: canonical_messages, system: system_text)
                   end
          projected = options.slice(*CONTRACT_OPTION_KEYS)
          params = projected[:params]
          raise ArgumentError, "dispatch params must be a Hash, got #{params.class}" unless params.nil? || params.is_a?(Hash)

          extras = NONCONTRACT_GENERATION_KEYS.each_with_object({}) do |key, acc|
            acc[key] = options[key] if options.key?(key) && !options[key].nil?
          end
          projected[:params] = (params || {}).merge(extras) unless extras.empty?
          [folded, projected]
        end

        def fold_system_into_messages(messages:, system:)
          message_class = Legion::Extensions::Llm::Canonical::Message
          first = messages.first
          if first.is_a?(message_class) && first.role.to_s == 'system'
            [first.with(content: system), *messages[1..]]
          else
            [message_class.build(role: :system, content: system), *messages]
          end
        end

        # Fleet response rehydration (0.8.0 E3): the v3 response envelope
        # carries the serialized Canonical::Response under :response — the
        # requestor-side mirror of the worker's rehydrate_wire_messages.
        # The v2 raw projection fields (content/tool_calls/usage/finish_reason)
        # are gone; a wrong-shape payload raises, never a half-translated hash.
        def normalize_fleet_result(result)
          normalized = if result.respond_to?(:transform_keys)
                         result.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                       else
                         {}
                       end
          payload = normalized[:response]
          unless payload.is_a?(Hash)
            raise ArgumentError,
                  'fleet response envelope missing the canonical response payload (protocol v3 E3)'
          end

          Legion::Extensions::Llm::Canonical::Response.from_hash(payload)
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
          log.debug "[llm][route_attempts] action=route_attempt provider=#{@resolved_provider} " \
                    "instance=#{@resolved_instance} model=#{@resolved_model} operation=#{operation} " \
                    "dispatch_path=#{dispatch_path} status=#{status} " \
                    "failure_reason=#{failure_reason.to_s[0, 200] if failure_reason}"
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
