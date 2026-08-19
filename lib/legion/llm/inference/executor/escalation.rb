# frozen_string_literal: true

require 'faraday'
require 'legion/extensions/llm/taxonomies'

module Legion
  module LLM
    module Inference
      class Executor
        # Escalation-area methods extracted from Executor verbatim (P4b §1.5, refactor-under-green).
        # Owns the provider-call lifecycle (single + escalating, sync + stream + responses-API),
        # error/retry classification, and the corresponding audit/metering emission.
        module Escalation
          # SSOT v3 single engine (sync). There is exactly one selector+executor
          # path: the request-scoped RoutingSession loop. No gate, no legacy
          # selector, no fallback.
          def step_provider_call
            run_provider_call_engine
          end

          # Populate resolved-state ivars from an AttemptContext so existing
          # emit_* calls (metering / prompt-audit / tool-audit) see the correct
          # provider/instance/model/tier/offering_id for this attempt.
          def populate_ssot_v3_resolved_state(attempt_context)
            sel = attempt_context.selection
            @resolved_provider     = sel.provider_family.to_sym
            @resolved_instance     = sel.instance_id.to_sym
            @resolved_model        = sel.model
            @resolved_tier         = attempt_context.lane.tier
            @resolved_offering_id  = sel.offering_id
            @resolved_offering_metadata = {}
            @current_attempt_context = attempt_context
            log.debug "[llm][executor] action=ssot_v3_resolved provider=#{@resolved_provider} " \
                      "instance=#{@resolved_instance} model=#{@resolved_model}"
          end

          # SSOT v3 single-attempt sync path. Selects via RoutingSession, delegates
          # dispatch+error-handling to run_provider_call_single (preserves existing
          # ProviderError → 529/502 behavior), classifies success.
          # SSOT v3 single engine (sync). One request-scoped RoutingSession owns
          # selection, one-and-done consumed-attempt identity, and retry. Each
          # attempt selects the exact provider+instance+model via Router.next_lane,
          # dispatches that EXACT callable (SelectionDispatch, via
          # ssot_v3_direct_dispatch), and classifies. A retriable outcome selects
          # the next eligible lane (the failed identity can never reappear); a
          # normalized instance_unavailable also marks that exact instance
          # unavailable (probe-cleared recovery — the original-incident fix). A
          # terminal outcome or attempt exhaustion raises RoutingRejected, which
          # the maintained route maps to the dialect HTTP status. No legacy
          # fallback, no HealthTracker mutation.
          def run_provider_call_engine
            @routing_session = Legion::LLM::Inference::RoutingSession.new(
              request: @request, requirements: @routing_requirements
            )
            @routing_requirements.maximum_attempts.times do
              attempt = @routing_session.next_attempt!(
                snapshot: Legion::Extensions::Llm::Inventory::Registry.snapshot
              )
              populate_ssot_v3_resolved_state(attempt)
              result = ssot_v3_execute_attempt
              action = @routing_session.classify(dispatch_result: result, attempt_context: attempt)
              unless action.disposition == :success
                lane = attempt.lane
                log.warn("[llm][executor] action=ssot_v3_attempt_failed attempt=#{attempt.attempt_number} " \
                         "lane=#{lane.tier}:#{lane.provider_family}:#{lane.instance_id}:#{lane_type_for(lane.operation)}:#{lane.model} " \
                         "provider=#{@resolved_provider} " \
                         "instance=#{@resolved_instance} model=#{@resolved_model} " \
                         "outcome_kind=#{result.outcome.kind} outcome_reason=#{result.outcome.reason.to_s[0, 200]} " \
                         "disposition=#{action.disposition}")
              end
              return if action.disposition == :success
              raise Legion::LLM::Errors::RoutingRejected.new(rejection: action.rejection) if action.disposition == :terminal
            end
            log.warn('[llm][executor] action=ssot_v3_attempts_exhausted kind=attempts_exhausted ' \
                     "reason=maximum attempts (#{@routing_requirements.maximum_attempts}) reached " \
                     "http_status=503 generation=#{Legion::Extensions::Llm::Inventory::Registry.snapshot.generation}")
            raise Legion::LLM::Errors::RoutingRejected.new(rejection: attempts_exhausted_rejection)
          ensure
            @current_attempt_context = nil
          end

          # Run one selected attempt through the exact callable. Returns a Phase 1
          # SelectionDispatch::Result (success value, or a normalized non-success
          # ProviderOutcome). Client-write/disconnect and daemon/programming errors
          # are NOT provider failures and propagate untouched (terminal).
          def ssot_v3_execute_attempt
            execute_provider_request
            Legion::LLM::Call::SelectionDispatch::Result.success(value: @raw_response)
          rescue StandardError => e
            raise e if non_provider_failure?(e)

            outcome = @last_ssot_dispatch_outcome
            @last_ssot_dispatch_outcome = nil
            if outcome.nil?
              log.warn("[llm][executor] action=ssot_v3_unnormalized_error class=#{e.class.name} " \
                       "message=#{e.message.to_s[0, 200]}")
            end
            outcome ||= Legion::Extensions::Llm::Routing::ProviderOutcome.new(
              kind: :provider_error, reason: e.class.name.to_s
            )
            Legion::LLM::Call::SelectionDispatch::Result.failure(outcome: outcome)
          end

          def attempts_exhausted_rejection
            Legion::Extensions::Llm::Routing::Rejection.new(
              kind:                 :attempts_exhausted,
              reason:               "maximum attempts (#{@routing_requirements.maximum_attempts}) reached",
              inventory_generation: Legion::Extensions::Llm::Inventory::Registry.snapshot.generation,
              candidate_counts:     {},
              http_status:          503
            )
          end

          # SSOT v3 §19 streaming preflight body. Called from Executor#stream_preflight!
          # (before the route opens SSE) once pre-provider steps have built
          # @routing_requirements. When the SSOT inventory path is active it selects
          # the exact lane through a per-request RoutingSession and acquires that
          # lane's DispatchLease, retaining both on the executor for the subsequent
          # call_stream. A rejection propagates as Errors::RoutingRejected (via
          # next_attempt!) so the route maps it to an HTTP status BEFORE headers —
          # never an SSE server_error. Always selects (single engine) — an empty
          # Registry yields a typed Rejection, never a legacy fallback.
          def ssot_v3_stream_preflight
            snap = Legion::Extensions::Llm::Inventory::Registry.snapshot
            @stream_session = Legion::LLM::Inference::RoutingSession.new(
              request: @request, requirements: @routing_requirements
            )
            attempt_context = @stream_session.next_attempt!(snapshot: snap)
            populate_ssot_v3_resolved_state(attempt_context)
            @preflight_lease = Legion::Extensions::Llm::Inventory::Registry.acquire(
              callable_handle: attempt_context.selection.callable_handle
            )
            lane = ssot_v3_stream_lane_hash(attempt_context)
            log.info "[llm][executor] action=ssot_v3_stream_preflight_selected " \
                     "lane=#{lane[:tier]}:#{lane[:provider_family]}:#{lane[:instance_id]}:#{lane[:type]}:#{lane[:model]} " \
                     "provider=#{@resolved_provider} model=#{@resolved_model}"
            lane
          end

          # Lane Hash consumed by StreamAssembler (#initial_lane, #begin_dispatch_on,
          # #provider_failover_pending!). Built from the exact Selection identity so
          # the failover debug trailers report real lane IDs — NOT 'unknown:pending'.
          def ssot_v3_stream_lane_hash(attempt_context)
            sel = attempt_context.selection
            lane = attempt_context.lane
            {
              id:              sel.lane_id,
              provider_family: sel.provider_family,
              instance_id:     sel.instance_id,
              model:           sel.model,
              tier:            lane.tier,
              type:            lane_type_for(lane.operation)
            }
          end

          # SSOT v3 §19 streaming dispatch + post-first-byte failover. Reuses the
          # preflight RoutingSession/AttemptContext when present; otherwise selects
          # inline (direct call_stream callers that did not preflight). On a
          # retriable provider failure it preserves the existing StreamAssembler
          # failover sequence: classify → retain consumed target + add justified
          # exclusions → provider_failover_pending!(from:) → strip cross-provider
          # thinking → next_attempt with a fresh snapshot → begin_dispatch_on(lane:)
          # → continue the SAME client SSE session (no replay, no custom switch
          # event). Terminal outcomes and exhaustion re-raise so the route emits the
          # dialect terminal SSE error (headers are already committed).
          def run_provider_call_ssot_v3_stream(&)
            session, attempt_context = ssot_v3_stream_session_and_attempt
            run_provider_call_ssot_v3_stream_loop(session: session, attempt_context: attempt_context, &)
          ensure
            @current_attempt_context = nil
          end

          # Resolve the (session, attempt_context) pair for streaming dispatch.
          # Preflight (§19) already selected + acquired before SSE opened: reuse it.
          # Otherwise select inline here (raises RoutingRejected → old-path fallback).
          def ssot_v3_stream_session_and_attempt
            return [@stream_session, @current_attempt_context] if @stream_session && @current_attempt_context

            snap = Legion::Extensions::Llm::Inventory::Registry.snapshot
            session = Legion::LLM::Inference::RoutingSession.new(
              request: @request, requirements: @routing_requirements
            )
            attempt_context = session.next_attempt!(snapshot: snap)
            populate_ssot_v3_resolved_state(attempt_context)
            [session, attempt_context]
          end

          # Bounded failover loop (no `loop do`/`retry`). RoutingSession bounds the
          # attempt count: next_attempt returns an attempts_exhausted Rejection once
          # requirements.maximum_attempts distinct targets are consumed.
          def run_provider_call_ssot_v3_stream_loop(session:, attempt_context:, &)
            current = attempt_context
            while current
              populate_ssot_v3_resolved_state(current)
              begin
                execute_provider_request_stream(&)
                session.classify(
                  dispatch_result: Legion::LLM::Call::SelectionDispatch::Result.success(value: @raw_response),
                  attempt_context: current
                )
                return
              rescue StandardError => e
                current = ssot_v3_stream_handle_failure(error: e, session: session, attempt_context: current)
              end
            end
          end

          # Classify one streaming provider failure and either continue to the next
          # eligible lane (returns the new AttemptContext) or re-raise (terminal,
          # non-provider, or no replacement). Client-write/disconnect and daemon
          # errors are never provider failures — they re-raise untouched.
          def ssot_v3_stream_handle_failure(error:, session:, attempt_context:)
            raise error if non_provider_failure?(error)

            outcome = ssot_v3_stream_failover_outcome(error)
            action = session.classify(
              dispatch_result: Legion::LLM::Call::SelectionDispatch::Result.failure(outcome: outcome),
              attempt_context: attempt_context
            )
            if action.disposition == :terminal
              log.warn("[llm][executor] action=ssot_v3_stream_terminal class=#{error.class.name} " \
                       "message=#{error.message.to_s[0, 200]} outcome_kind=#{outcome.kind}")
            end
            raise error if action.disposition == :terminal

            # Preserve the existing StreamAssembler failover sequence (§19). The
            # assembler clears its partial canonical buffer and strips provider-bound
            # thinking/reasoning before the next provider renders a clean start.
            @stream_observer&.provider_failover_pending!(from: ssot_v3_stream_lane_hash(attempt_context))

            # The consumed target for the old provider is done; a re-selected lane on
            # a different callable acquires its own lease inside SelectionDispatch.
            release_preflight_lease

            snap = Legion::Extensions::Llm::Inventory::Registry.snapshot
            nxt = session.next_attempt(snapshot: snap)
            if nxt.is_a?(Legion::Extensions::Llm::Routing::Rejection)
              log.warn("[llm][executor] action=ssot_v3_stream_exhausted kind=#{nxt.kind} reason=#{nxt.reason.to_s[0, 200]} " \
                       "class=#{error.class.name} message=#{error.message.to_s[0, 200]}")
            end
            raise error if nxt.is_a?(Legion::Extensions::Llm::Routing::Rejection)

            @stream_observer&.begin_dispatch_on(lane: ssot_v3_stream_lane_hash(nxt))
            next_lane = nxt.lane
            next_identity = [
              next_lane.tier, next_lane.provider_family, next_lane.instance_id,
              lane_type_for(next_lane.operation), next_lane.model
            ].join(':')
            log.warn "[llm][executor] action=ssot_v3_stream_failover from_kind=#{outcome.kind} " \
                     "outcome_reason=#{outcome.reason.to_s[0, 200]} to_lane=#{next_identity}"
            nxt
          end

          def lane_type_for(operation)
            Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: operation)
          end

          # Map a raised streaming provider error to a Phase 1 ProviderOutcome for
          # classification. The exact outcome from SelectionDispatch is preserved
          # losslessly by ssot_v3_direct_dispatch (@last_ssot_dispatch_outcome);
          # fall back to a conservative :provider_error when it is absent.
          def ssot_v3_stream_failover_outcome(error)
            outcome = @last_ssot_dispatch_outcome
            @last_ssot_dispatch_outcome = nil
            return outcome if outcome.is_a?(Legion::Extensions::Llm::Routing::ProviderOutcome)

            Legion::Extensions::Llm::Routing::ProviderOutcome.new(
              kind: :provider_error, reason: error.class.name.to_s
            )
          end

          def execute_provider_request
            @timestamps[:provider_start] = Time.now
            @timeline.record(
              category: :provider, key: 'provider:request_sent',
              exchange_id: @exchange_id, direction: :outbound,
              detail: "calling #{@resolved_provider}",
              from: 'pipeline', to: "provider:#{@resolved_provider}"
            )

            raise Legion::LLM::ProviderError, "Native provider not registered: #{@resolved_provider}" unless fleet_dispatch? || use_native_dispatch?(@resolved_provider)

            execute_provider_request_native

            @timestamps[:provider_end] = Time.now
            record_provider_response
          end

          def execute_provider_request_native
            result = execute_native_tool_loop
            merge_response_offering_metadata(result.metadata) if result.respond_to?(:metadata)
            @raw_response = result
            @tool_loop_messages = @last_tool_loop_messages if @last_tool_loop_messages
          end

          def record_provider_response
            duration_ms = ((@timestamps[:provider_end] - @timestamps[:provider_start]) * 1000).to_i
            log.debug("[pipeline][provider] action=response_received provider=#{@resolved_provider} model=#{@resolved_model} duration_ms=#{duration_ms}")
            @timeline.record(
              category: :provider, key: 'provider:response_received',
              exchange_id: @exchange_id, direction: :inbound,
              detail: 'response received',
              from: "provider:#{@resolved_provider}", to: 'pipeline',
              duration_ms: duration_ms
            )
          end

          # Detect client-side stream errors (disconnects, broken pipes, socket timeouts)
          # that originate from writing back to the HTTP client, not from the provider itself.
          # Puma::ConnectionError is a RuntimeError (NOT an IOError), so it slips past the
          # StreamAssembler's rescue IOError/EPIPE guards and reaches the executor raw — the
          # exact class the production logs show tripping the vLLM circuit. StreamClosed is the
          # assembler's own wrapper raised once the client socket is confirmed dead.
          def client_stream_error?(err)
            name = err.class.name.to_s
            msg  = err.message.to_s
            name.include?('Puma::ConnectionError') ||
              name.include?('StreamAssembler::StreamClosed') ||
              name.include?('Errno::EPIPE') ||
              (name.include?('IOError') && msg.include?('closed')) ||
              (name.include?('IOError') && msg.include?('already closed')) ||
              name.include?('EOFError') ||
              name.include?('Errno::ECONNRESET') ||
              name.include?('Errno::ECONNABORTED')
          end

          # G25 / B-H / PR #152 C5/C6: Internal errors (daemon NoMethodError/ArgumentError) come from
          # shared daemon code — retrying on a different lane guarantees the same crash. Classified as
          # terminal: raise immediately, never retry, never trip circuits, never push to tried_lanes.
          def internal_error?(err)
            err.is_a?(::NoMethodError) || err.is_a?(::ArgumentError) || err.is_a?(::NotImplementedError)
          end

          # SSE assembly / canonical parse / translation errors originate inside LegionIO's
          # own stream-assembly and translation layer, not from the upstream provider. Like
          # daemon/programming errors, they must never trip a provider circuit or escalate to
          # another lane — the upstream is healthy; the bug is ours. Matched by class name so
          # this stays provider-agnostic (N×N invariant) and does not couple to lex-llm gems.
          def sse_translation_error?(err)
            name = err.class.name.to_s
            name.include?('JSON::ParseError') ||
              name.include?('JSON::ParserError')
          end

          # The circuit breaker answers exactly one question: is the upstream LLM PROVIDER
          # itself broken/down? These three families are NOT provider failures and must never
          # trip a circuit, report provider health, or escalate to another lane:
          #   (1) client-side write/disconnect (client socket died) — client_stream_error?
          #   (2) SSE assembly / canonical parse / translation (LegionIO's own bugs)
          #   (3) daemon/programming errors (NoMethodError/ArgumentError) — internal_error?
          # Provider-agnostic: matches on exception family, never on provider name.
          def non_provider_failure?(err)
            client_stream_error?(err) || sse_translation_error?(err) || internal_error?(err)
          end

          # SSOT v3 single engine (streaming). Preflight (Executor#stream_preflight!)
          # already selected + acquired the exact lane before SSE opened; this runs
          # the dispatch + post-first-byte failover through the same RoutingSession
          # and consumed-attempt set. Provider failures are classified inside the
          # failover loop (no HealthTracker mutation); terminal/exhausted outcomes
          # re-raise so the route emits the dialect terminal SSE error.
          def step_provider_call_stream(&)
            run_provider_call_ssot_v3_stream(&)
          end

          def execute_provider_request_stream(&)
            @timestamps[:provider_start] = Time.now
            @timeline.record(
              category: :provider, key: 'provider:request_sent',
              exchange_id: @exchange_id, direction: :outbound,
              detail: "streaming from #{@resolved_provider}",
              from: 'pipeline', to: "provider:#{@resolved_provider}"
            )

            raise Legion::LLM::ProviderError, "Native provider not registered: #{@resolved_provider}" unless fleet_dispatch? || use_native_dispatch?(@resolved_provider)

            execute_provider_request_stream_native(&)

            @timestamps[:provider_end] = Time.now
            record_provider_response
          end

          def execute_provider_request_stream_native(&)
            result = execute_native_streaming_tool_loop(&)
            merge_response_offering_metadata(result.metadata) if result.respond_to?(:metadata)
            @raw_response = result
          end

          # REMOVED: execute_provider_request_responses
          # N×N LAW: only one canonical execution path via execute_provider_request_native.
          # Responses API format is handled by the API namespace translator → canonical conversion.
        end
      end
    end
  end
end
