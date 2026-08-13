# frozen_string_literal: true

require 'faraday'

module Legion
  module LLM
    module Inference
      class Executor
        # Escalation-area methods extracted from Executor verbatim (P4b §1.5, refactor-under-green).
        # Owns the provider-call lifecycle (single + escalating, sync + stream + responses-API),
        # error/retry classification, and the corresponding audit/metering emission.
        module Escalation
          def step_provider_call
            escalation = pipeline_escalation_enabled?
            log.debug "[llm][executor] action=step_provider_call provider=#{@resolved_provider} model=#{@resolved_model} escalation=#{escalation}"
            if ssot_v3_inventory_active?
              run_provider_call_ssot_v3_single
            elsif escalation
              run_provider_call_with_attempts(routing_payload: build_routing_payload_from_resolved)
            else
              run_provider_call_single
            end
          end

          # True when the Phase 1 Registry has at least one activated lane for
          # the RESOLVED provider AND RequestRequirements were built in step_routing.
          # Gating on @resolved_provider prevents state-leaked ssot_v3-tagged specs
          # from activating the SSOT v3 path for unrelated providers.
          def ssot_v3_inventory_active?
            return false if @routing_requirements.nil?
            return false if @resolved_provider.nil?

            snap = Legion::Extensions::Llm::Inventory::Registry.snapshot
            return false unless snap.generation.positive?

            resolved = @resolved_provider.to_s
            snap.each_instance.any? { |inst| inst.instance_key.provider_family.to_s == resolved }
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.ssot_v3_inventory_active')
            false
          end

          # Populate resolved-state ivars from an AttemptContext so existing
          # emit_* calls (metering / prompt-audit / tool-audit) see the correct
          # provider/instance/model/tier/offering_id for this attempt.
          def populate_ssot_v3_resolved_state(attempt_context)
            sel = attempt_context.selection
            @resolved_provider     = sel.provider_family.to_sym
            @resolved_instance     = sel.instance_id.to_sym
            @resolved_model        = sel.model
            # @resolved_tier already set by step_routing; leave it intact for metering.
            @resolved_offering_id  = sel.offering_id
            @resolved_offering_metadata = {}
            @current_attempt_context = attempt_context
            log.debug "[llm][executor] action=ssot_v3_resolved provider=#{@resolved_provider} " \
                      "instance=#{@resolved_instance} model=#{@resolved_model}"
          end

          # SSOT v3 single-attempt sync path. Selects via RoutingSession, delegates
          # dispatch+error-handling to run_provider_call_single (preserves existing
          # ProviderError → 529/502 behavior), classifies success.
          def run_provider_call_ssot_v3_single
            snap = Legion::Extensions::Llm::Inventory::Registry.snapshot
            session = Legion::LLM::Inference::RoutingSession.new(
              request: @request, requirements: @routing_requirements
            )
            attempt_context = session.next_attempt!(snapshot: snap)
            populate_ssot_v3_resolved_state(attempt_context)
            run_provider_call_single
            # On success, classify using a synthetic success Result (no retry loop needed —
            # error handling is fully delegated to run_provider_call_single which re-raises).
            fake_result = Legion::LLM::Call::SelectionDispatch::Result.success(value: @raw_response)
            session.classify(dispatch_result: fake_result, attempt_context: attempt_context)
          rescue Legion::LLM::Errors::RoutingRejected => e
            # No lane available from Phase 1 Registry — degrade gracefully to old path.
            log.warn "[llm][executor] action=ssot_v3_routing_rejected reason=#{e.rejection&.reason} falling_back=old_path"
            @current_attempt_context = nil
            run_provider_call_single
          ensure
            @current_attempt_context = nil
          end

          # SSOT v3 single-attempt stream path. Mirrors run_provider_call_ssot_v3_single.
          def run_provider_call_ssot_v3_stream(&block)
            snap = Legion::Extensions::Llm::Inventory::Registry.snapshot
            session = Legion::LLM::Inference::RoutingSession.new(
              request: @request, requirements: @routing_requirements
            )
            attempt_context = session.next_attempt!(snapshot: snap)
            populate_ssot_v3_resolved_state(attempt_context)
            execute_provider_request_stream(&block)
            # On success, classify (no retry loop — errors propagate from execute_provider_request_stream).
            fake_result = Legion::LLM::Call::SelectionDispatch::Result.success(value: @raw_response)
            session.classify(dispatch_result: fake_result, attempt_context: attempt_context)
          rescue Legion::LLM::Errors::RoutingRejected => e
            log.warn "[llm][executor] action=ssot_v3_stream_routing_rejected reason=#{e.rejection&.reason} falling_back=old_path"
            @current_attempt_context = nil
            execute_provider_request_stream(&block)
          ensure
            @current_attempt_context = nil
          end

          # Build a minimal routing_payload from the already-resolved routing state.
          # C2 (PayloadBuilder) will replace this with a proper single-ingress build from headers+body.
          # This bridge keeps the loop working in C1 while the old chain machinery still exists.
          #
          # IMPORTANT: providers/instances/tiers are intentionally NOT pinned here.
          # Pinning providers: [:bedrock] would prevent cross-provider failover — the router
          # returns nil after bedrock lanes are exhausted, raising EscalationExhausted prematurely.
          # The preferred provider is expressed via the model filter (models: [model]) and by the
          # routing payload built in C2 from explicit x-legion-* headers (hard filters) vs body hints.
          # For the while remaining.positive? loop, tried_lanes exclusion handles exhaustion naturally:
          # after all bedrock lanes are in tried_lanes, the router selects the next-best provider.
          def build_routing_payload_from_resolved
            estimated = estimate_request_tokens
            # Include the resolved model as a soft filter so request_lane picks the requested model
            # from whichever provider has it. No provider/tier/instance pinning — that would prevent
            # cross-provider failover and break the while remaining.positive? escalation loop.
            models = @resolved_model ? [@resolved_model.to_s] : []

            {
              type:              :inference,
              tiers:             [],
              providers:         [],
              instances:         [],
              models:            models,
              capabilities:      chain_required_capabilities,
              privacy:           (@proactive_tier_assignment&.dig(:privacy) || :normal).to_sym,
              estimated_context: estimated.positive? ? estimated : nil,
              tried_lanes:       [],
              max_attempts:      pipeline_escalation_max_attempts
            }
          end

          def run_provider_call_single
            execute_provider_request
          rescue Legion::LLM::AuthError, Faraday::UnauthorizedError, Faraday::ForbiddenError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.auth',
                             provider: @resolved_provider, model: @resolved_model)
            report_provider_failure(e, status: 'auth_failed')
            raise e.is_a?(Legion::LLM::AuthError) ? e : Legion::LLM::AuthError.new(e.message)
          rescue Legion::LLM::ContextOverflow => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.context_overflow',
                             provider: @resolved_provider, model: @resolved_model)
            emit_error_audit(e, status: 'context_overflow')
            raise
          rescue Legion::LLM::RateLimitError, Faraday::TooManyRequestsError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.rate_limit',
                             provider: @resolved_provider, model: @resolved_model)
            report_provider_failure(e, status: 'rate_limited')
            raise e.is_a?(Legion::LLM::RateLimitError) ? e : Legion::LLM::RateLimitError.new(e.message, retry_after: extract_retry_after(e))
          rescue Legion::LLM::ProviderDown, Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.provider_down',
                             provider: @resolved_provider, model: @resolved_model)
            report_provider_failure(e, status: 'provider_down')
            raise e.is_a?(Legion::LLM::ProviderDown) ? e : Legion::LLM::ProviderDown.new(e.message)
          rescue Legion::LLM::ProviderError, Faraday::ServerError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.provider_error',
                             provider: @resolved_provider, model: @resolved_model)
            report_provider_failure(e, status: 'provider_error')
            raise e.is_a?(Legion::LLM::ProviderError) ? e : Legion::LLM::ProviderError.new(e.message)
          end

          # Errors scoped to a single account/instance (its credentials, billing, or
          # quota) rather than to the model itself. A sibling instance of the same
          # provider+model can still succeed, so these must not skip the whole model.
          def account_specific_error?(error)
            message = error.respond_to?(:message) ? error.message.to_s : error.to_s
            message.match?(/credit balance|insufficient (?:credit|funds|quota|balance)|payment required|billing|quota (?:exceeded|exhausted)|over quota/i)
          end

          def record_escalation_failure(err, resolution, start_time, outcome:, operation:, handled: false)
            @last_escalation_error = err
            duration_ms = ((Time.now - start_time) * 1000).round
            handle_exception(err, level: :warn, handled: handled, operation: operation,
                                 provider: resolution.provider, model: resolution.model, duration_ms: duration_ms)
            if request_payload_error?(err)
              log.error "[llm][escalation] action=request_payload_error provider=#{resolution.provider} " \
                        "instance=#{resolution.instance || 'default'} model=#{resolution.model} " \
                        "error=#{err.message.to_s[0, 500]} daemon_side_payload_bug=true provider_health=false"
            elsif non_provider_failure?(err)
              # The circuit breaker answers ONE question: "is the upstream LLM provider
              # itself broken/down?" Client-side write/disconnect (the client socket died),
              # SSE/canonical parse/translation (LegionIO's own bugs), and daemon/programming
              # errors are NOT provider failures. Never report provider health or trip a
              # circuit for them — doing so misattributes a dead client socket (or our own
              # bug) to a healthy upstream and trips its lane. This is the dominant field
              # failure this method previously caused.
              log.warn "[llm][escalation] action=non_provider_error provider=#{resolution.provider} " \
                       "instance=#{resolution.instance || 'default'} model=#{resolution.model} " \
                       "error=#{err.class}: #{err.message.to_s[0, 300]} provider_health=untouched"
            elsif account_specific_error?(err)
              # Account-scoped failure (credit balance, payment, quota). It is
              # deterministic — it will fail every call until the operator tops up —
              # so DEPRIORITIZE this instance immediately by tripping its per-instance
              # circuit, to stop wasting calls on an account that cannot work. The
              # circuit is per (provider, instance), so healthy sibling instances and
              # the provider globally are unaffected, and its cooldown -> half_open
              # re-probe auto-recovers the instance once credits return. Do NOT
              # deny_model — the model is fine on other instances/accounts.
              log.warn "[llm][escalation] action=account_scoped_error provider=#{resolution.provider} " \
                       "instance=#{resolution.instance || 'default'} model=#{resolution.model} " \
                       "error=#{err.message.to_s[0, 300]} deprioritized=true model_denied=false"
              Legion::LLM::Router.health_tracker.trip_circuit( # allowlist:write-side
                provider: resolution.provider, instance: resolution.instance, reason: err.message
              )
            elsif authentication_error?(err) || config_error?(err)
              Legion::LLM::Router.health_tracker.deny_model( # allowlist:write-side
                provider: resolution.provider,
                model:    resolution.model,
                instance: resolution.instance,
                reason:   err.message
              )
              Legion::LLM::Router.health_tracker.trip_circuit( # allowlist:write-side
                provider: resolution.provider,
                instance: resolution.instance,
                reason:   err.message
              )
            elsif !context_overflow_error?(err)
              Legion::LLM::Router.health_tracker.report(provider: resolution.provider, instance: resolution.instance, # allowlist:write-side
                                                        offering_id: resolution.offering_id,
                                                        signal: :error, value: 1,
                                                        metadata: { reason: err.class.name, message: err.message.to_s[0, 500],
                                                                    model: resolution.model })
            end
            @escalation_history << escalation_attempt_hash(
              resolution,
              outcome:     outcome,
              failures:    [err.class.name],
              duration_ms: duration_ms
            )
            @timeline.record(
              category: :provider, key: 'escalation:attempt', direction: :internal,
              detail: "attempt #{@escalation_history.size}: #{resolution.provider}:#{resolution.model} => #{outcome}",
              from: 'pipeline', to: "provider:#{resolution.provider}"
            )
            emit_escalation_attempt_metering(
              provider:    resolution.provider,
              model:       resolution.model,
              duration_ms: duration_ms,
              attempt:     @escalation_history.size,
              status:      'error',
              error:       err
            )
            emit_escalation_attempt_audit(
              provider:    resolution.provider,
              model:       resolution.model,
              outcome:     outcome,
              duration_ms: duration_ms,
              error:       err,
              attempt:     @escalation_history.size
            )
          end

          def escalation_attempt_hash(resolution, outcome:, failures:, duration_ms:)
            attempt = { model: resolution.model, provider: resolution.provider, tier: resolution.tier,
                        outcome: outcome, failures: failures, duration_ms: duration_ms }
            attempt[:offering_id] = resolution.offering_id if resolution.offering_id
            attempt[:offering_metadata] = resolution.offering_metadata unless resolution.offering_metadata.empty?
            attempt
          end

          def pipeline_escalation_enabled?
            esc = Legion::Settings[:llm][:routing][:escalation]
            esc[:enabled] == true && esc[:pipeline_enabled] == true
          end

          def pipeline_escalation_max_attempts
            esc = Legion::Settings[:llm][:routing][:escalation]
            esc[:max_attempts] || 3
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
            report_provider_health(:success, duration_ms) if @resolved_offering_id
            log.debug("[pipeline][provider] action=response_received provider=#{@resolved_provider} model=#{@resolved_model} duration_ms=#{duration_ms}")
            @timeline.record(
              category: :provider, key: 'provider:response_received',
              exchange_id: @exchange_id, direction: :inbound,
              detail: 'response received',
              from: "provider:#{@resolved_provider}", to: 'pipeline',
              duration_ms: duration_ms
            )
          end

          def report_provider_failure(error, provider: @resolved_provider, instance: @resolved_instance,
                                      model: @resolved_model, offering_id: @resolved_offering_id,
                                      status: 'provider_error')
            emit_error_audit(error, status: status, provider: provider, model: model)
            return if request_payload_error?(error)
            return if context_overflow_error?(error)
            # Non-provider failures (client-write/disconnect, SSE/parse/translation, daemon
            # programming errors) never reflect on provider health. The upstream is healthy;
            # counting these as provider :error trips a live lane's circuit for a dead client
            # socket or a LegionIO bug — the misattribution behind the field restart-cascade.
            return if non_provider_failure?(error)

            if authentication_error?(error) || config_error?(error)
              Legion::LLM::Router.health_tracker.deny_model( # allowlist:write-side
                provider: provider,
                model:    model,
                instance: instance,
                reason:   error.message
              )
              Legion::LLM::Router.health_tracker.trip_circuit( # allowlist:write-side
                provider: provider,
                instance: instance,
                reason:   error.message
              )
              return
            end

            Legion::LLM::Router.health_tracker.report( # allowlist:write-side
              provider: provider, instance: instance,
              offering_id: offering_id, signal: :error, value: 1,
              metadata: { reason: error.class.name, message: error.message.to_s[0, 500], model: model }
            )
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.report_provider_failure')
          end

          def report_provider_health(signal, duration_ms, metadata: {})
            return unless defined?(Legion::LLM::Router) && Legion::LLM::Router.routing_enabled?

            Legion::LLM::Router.health_tracker.report(provider: @resolved_provider, instance: @resolved_instance, # allowlist:write-side
                                                      offering_id: @resolved_offering_id,
                                                      signal: signal, value: 1, metadata: metadata.merge(duration_ms: duration_ms))
            Legion::LLM::Router.health_tracker.report(provider: @resolved_provider, instance: @resolved_instance, # allowlist:write-side
                                                      offering_id: @resolved_offering_id,
                                                      signal: :latency, value: duration_ms, metadata: {})
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.report_provider_health')
          end

          def extract_retry_after(error)
            return nil unless error.respond_to?(:response) && error.response.is_a?(Hash)

            error.response[:headers]&.fetch('retry-after', nil)&.to_i
          end

          def emit_error_audit(error, status:, provider: @resolved_provider, model: @resolved_model)
            routing = { provider: provider, model: model }
            routing[:offering_id] = @resolved_offering_id if @resolved_offering_id
            routing[:offering_metadata] = @resolved_offering_metadata if @resolved_offering_metadata&.any?

            Legion::LLM::Audit.emit_prompt(
              request_id:      @request.id,
              conversation_id: @request.conversation_id,
              caller:          @request.caller,
              routing:         routing,
              tokens:          {},
              status:          status,
              error:           { class: error.class.name, message: error.message },
              tracing:         @tracing,
              timestamp:       Time.now,
              request_type:    'chat',
              messages:        @request.messages
            )
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.emit_error_audit')
          end

          def emit_escalation_attempt_audit(provider:, model:, outcome:, duration_ms:, error: nil, attempt: 1)
            routing = { provider: provider, model: model }
            routing[:offering_id] = @resolved_offering_id if @resolved_offering_id
            routing[:offering_metadata] = @resolved_offering_metadata if @resolved_offering_metadata&.any?

            tokens = {}
            if @extracted_tokens
              input_tokens  = @extracted_tokens.respond_to?(:input_tokens)  ? @extracted_tokens.input_tokens.to_i  : 0
              output_tokens = @extracted_tokens.respond_to?(:output_tokens) ? @extracted_tokens.output_tokens.to_i : 0
              thinking      = @extracted_tokens.respond_to?(:thinking_tokens) ? @extracted_tokens.thinking_tokens.to_i : 0
              tokens = { input_tokens: input_tokens, output_tokens: output_tokens, thinking_tokens: thinking }.compact
            end

            content = extract_response_content
            thinking_response = extract_thinking

            Legion::LLM::Audit.emit_prompt(
              request_id:            @request.id,
              conversation_id:       @request.conversation_id,
              caller:                @request.caller,
              routing:               routing,
              tokens:                tokens,
              status:                outcome == :success ? 'success' : 'error',
              provider_response_ref: "#{@request.id}:attempt:#{attempt}",
              latency_ms:            duration_ms,
              response_content:      content,
              response_thinking:     thinking_response,
              error:                 error ? { class: error.class.name, message: error.message } : nil,
              tracing:               @tracing,
              timestamp:             Time.now,
              request_type:          'chat',
              messages:              @request.messages
            )
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.emit_escalation_attempt_audit')
          end

          def emit_escalation_attempt_metering(provider:, model:, duration_ms:, attempt: 1, status: 'success',
                                               error: nil, provider_submitted: true)
            @extracted_tokens ||= extract_tokens
            input_tokens  = @extracted_tokens.respond_to?(:input_tokens)  ? @extracted_tokens.input_tokens.to_i  : 0
            output_tokens = @extracted_tokens.respond_to?(:output_tokens) ? @extracted_tokens.output_tokens.to_i : 0
            cost_usd = estimate_cost(input_tokens, output_tokens)

            event = Legion::LLM::Inference::Steps::Metering.build_event(
              provider:           provider,
              model_id:           model,
              offering_id:        @resolved_offering_id,
              offering_metadata:  @resolved_offering_metadata,
              tier:               @resolved_tier,
              request_type:       if @request.respond_to?(:request_type)
                                    @request.request_type
                                  else
                                    'chat'
                                  end,
              input_tokens:       input_tokens,
              output_tokens:      output_tokens,
              latency_ms:         duration_ms,
              wall_clock_ms:      duration_ms,
              cost_usd:           cost_usd,
              request_id:         @request.id,
              conversation_id:    @request.conversation_id,
              correlation_id:     @tracing&.dig(:correlation_id),
              caller:             @request.caller,
              identity:           metering_identity,
              billing:            @request.billing,
              routing_reason:     "escalation_attempt:#{attempt}",
              messages:           @request.messages,
              response_content:   extract_response_content,
              response_thinking:  extract_thinking,
              status:             status,
              error:              error_metadata(error),
              provider_submitted: provider_submitted
            )
            Legion::LLM::Inference::Steps::Metering.publish_or_spool(event)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.emit_escalation_attempt_metering')
          end

          def request_payload_error?(err)
            name = err.class.name.to_s
            msg = err.message.to_s
            REQUEST_PAYLOAD_ERROR_PATTERNS.any? { |pat| pat.match?(name) || pat.match?(msg) }
          end

          def config_error?(err)
            name = err.class.name.to_s
            msg = err.message.to_s
            CONFIG_ERROR_PATTERNS.any? { |pat| pat.match?(name) || pat.match?(msg) }
          end

          def authentication_error?(err)
            err.is_a?(Legion::LLM::AuthError) ||
              err.is_a?(Faraday::UnauthorizedError) ||
              err.is_a?(Faraday::ForbiddenError)
          end

          def error_metadata(err)
            return nil unless err

            { class: err.class.name, message: err.message.to_s }
          end

          def context_overflow_error?(err)
            err.is_a?(Legion::LLM::ContextOverflow) ||
              err.class.name.to_s.include?('ContextLength') ||
              CONTEXT_OVERFLOW_ERROR_PATTERNS.any? { |pat| pat.match?(err.message.to_s) }
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

          # A client-side write/disconnect is a clean cancellation, not a provider failure.
          # Distinguished from the broader non_provider_failure? set so the streaming loop can
          # route it to a clean disconnect exit that STILL emits the ledger/metering event
          # (invariant #6) while leaving provider health untouched.
          def client_disconnect_error?(err)
            client_stream_error?(err)
          end

          def larger_context_lane_available?(lane:, payload:, **)
            current_context = lane.dig(:limits, :context_window).to_i
            return false unless current_context.positive?

            Legion::LLM::Inventory.lanes.any? do |candidate|
              next false if payload[:tried_lanes].include?(candidate[:id])
              next false if candidate[:lane_weight].to_i <= 0

              candidate_context = candidate.dig(:limits, :context_window).to_i
              candidate_context > current_context
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.larger_context_lane_available')
            false
          end

          # Classify error for the while remaining.positive? loop (G26 / D-C).
          # internal_error MUST be checked BEFORE account_specific (G25 / B-H):
          # a daemon NoMethodError must never be treated as a retriable account-scoped failure.
          def classify_error(error:, **)
            return :context_overflow  if context_overflow_error?(error)
            return :payload_error     if request_payload_error?(error)
            return :policy_denied     if error.is_a?(Legion::LLM::ModelNotAllowed)
            return :internal_error    if internal_error?(error) # daemon bug; terminal before account_specific (G25)
            # non_provider (client-write/disconnect, SSE/parse/translation) is terminal and
            # must be classified BEFORE account_specific/transient: a dead client socket or a
            # LegionIO parse bug must never trip a provider circuit or escalate to another lane
            # (senseless — the upstream is healthy). Checked after :internal_error so daemon
            # programming errors keep their pre-existing, more-specific label (both are terminal).
            return :non_provider      if non_provider_failure?(error)
            return :account_specific  if authentication_error?(error) ||
                                         config_error?(error) ||
                                         account_specific_error?(error)

            :transient
          end

          # Called after each failed dispatch in the while remaining.positive? loop.
          # Updates the routing payload's tried_lanes and/or trips the health circuit.
          # Terminal errors re-raise immediately so the caller's while loop stops.
          def classify_and_accumulate_exclusions(error:, lane:, payload:, **)
            case classify_error(error: error)
            when :context_overflow
              raise error unless larger_context_lane_available?(lane: lane, payload: payload)

              payload[:tried_lanes] << lane[:id]

            when :internal_error, :payload_error, :policy_denied, :non_provider
              raise error
            when :account_specific
              # Account/instance-scoped failure: trip the per-instance circuit.
              # All lanes for this instance go lane_weight ≤ 0; sibling instances stay eligible.
              log.warn("[llm][escalation] action=account_specific_error lane=#{lane[:id]} " \
                       "provider=#{lane[:provider_family]} instance=#{lane[:instance_id]} " \
                       "error=#{error.class}: #{error.message.to_s[0, 200]}")
              Legion::LLM::Router.health_tracker.trip_circuit( # allowlist:write-side
                provider: lane[:provider_family], instance: lane[:instance_id], reason: error.message
              )
            else
              payload[:tried_lanes] << lane[:id]
            end
          rescue Legion::LLM::ModelNotAllowed, ::NoMethodError, ::ArgumentError
            raise
          rescue StandardError => e
            raise if request_payload_error?(e)
            raise if context_overflow_error?(e)
            raise if non_provider_failure?(e) # client-write/disconnect + SSE/parse: terminal, never accumulate

            handle_exception(e, level: :warn, operation: 'llm.pipeline.classify_and_accumulate_exclusions',
                                lane: lane[:id])
            payload[:tried_lanes] << lane[:id]
          end

          # G26 / D-C: The bounded while remaining.positive? loop.
          # Replaces the @escalation_chain iteration. Bounded by construction — remaining only decreases.
          # No loop do, no retry, no redo inside this block.
          #
          # G27 / D-G: Dual-error semantics tracked by attempt_idx == 0:
          #   NoLaneAvailable   — request_lane returned nil on first try (attempt_idx == 0)
          #   EscalationExhausted — tried at least one lane (attempt_idx >= 1) then ran out
          #
          # First-attempt seeding: if step_routing already resolved a provider/model, we look up the
          # corresponding Inventory lane for that (provider, instance, model) to use as the first lane.
          # This preserves step_routing's resolution while keeping the loop-based retry mechanism.
          # N×N: single canonical escalation loop — no provider-specific branches.
          # The API namespace translator converts all client formats to canonical form;
          # this loop dispatches only through execute_provider_request / execute_provider_request_stream.
          def run_provider_call_with_attempts(routing_payload:, assembler: nil, stream_block: nil)
            remaining      = routing_payload[:max_attempts] || Legion::Settings[:llm][:routing][:max_attempts]
            total_attempts = remaining
            attempt_idx    = 0
            last_error     = nil

            log.debug('[llm][executor] action=run_provider_call_with_attempts ' \
                      "max_attempts=#{remaining} provider=#{@resolved_provider} model=#{@resolved_model}")

            while remaining.positive?
              lane = select_next_lane(routing_payload: routing_payload, attempt_idx: attempt_idx)

              if lane.nil?
                if attempt_idx.zero?
                  err = Legion::LLM::Errors::NoLaneAvailable.new(
                    filters: routing_payload.slice(:tiers, :providers, :instances, :models,
                                                   :capabilities, :thinking, :privacy, :estimated_context)
                  )
                  log.warn("[llm][executor] action=no_lane_available filters=#{err.filters.inspect}")
                  emit_error_audit(err, status: 'no_lane_available')
                else
                  err = Legion::LLM::Errors::EscalationExhausted.new(
                    attempts:    attempt_idx,
                    tried_lanes: routing_payload[:tried_lanes],
                    last_error:  last_error
                  )
                  log.warn("[llm][executor] action=escalation_exhausted_mid_loop attempts=#{attempt_idx} " \
                           "tried=#{routing_payload[:tried_lanes].size}")
                  emit_error_audit(err, status: 'escalation_exhausted')
                end
                raise err
              end

              remaining   -= 1
              attempt_idx += 1

              @resolved_provider         = lane[:provider_family]
              @resolved_instance         = lane[:instance_id]
              @resolved_model            = lane[:model]
              @resolved_tier             = lane[:tier]
              @resolved_offering_id      = lane[:id]
              @resolved_offering_metadata = normalize_offering_metadata(
                lane.slice(:canonical_model_alias, :limits, :cost, :capabilities).compact
              )

              log.info("[llm][executor] action=dispatch_attempt attempt=#{attempt_idx}/#{total_attempts} " \
                       "lane=#{lane[:id]} provider=#{@resolved_provider} model=#{@resolved_model}")

              assembler&.begin_dispatch_on(lane: lane) if assembler.respond_to?(:begin_dispatch_on)

              start_time = Time.now
              begin
                # N×N: single canonical dispatch path — no provider-specific branches.
                # The API namespace translator converts all client formats (OpenAI Chat,
                # OpenAI Responses, Anthropic Messages) to canonical before the executor
                # receives the request. The lex-llm-* provider adapter handles wire format.
                if stream_block
                  execute_provider_request_stream(&stream_block)
                else
                  execute_provider_request
                end
                duration_ms = ((Time.now - start_time) * 1000).round
                report_provider_health(:success, duration_ms) if @resolved_offering_id
                @timeline.record(
                  category: :provider, key: 'escalation:attempt', direction: :internal,
                  detail: "attempt #{attempt_idx}: #{@resolved_provider}:#{@resolved_model} => success",
                  from: 'pipeline', to: "provider:#{@resolved_provider}"
                )
                emit_escalation_attempt_metering(provider: @resolved_provider, model: @resolved_model,
                                                 duration_ms: duration_ms, attempt: attempt_idx)
                emit_escalation_attempt_audit(provider: @resolved_provider, model: @resolved_model,
                                              outcome: :success, duration_ms: duration_ms,
                                              attempt: attempt_idx)
                return
              rescue StandardError => e
                last_error  = e
                duration_ms = ((Time.now - start_time) * 1000).round
                record_escalation_failure(e,
                                          Legion::LLM::Router::Resolution.new(
                                            tier: @resolved_tier, provider: @resolved_provider,
                                            instance: @resolved_instance, model: @resolved_model,
                                            offering_id: @resolved_offering_id
                                          ),
                                          start_time,
                                          outcome:   :error,
                                          operation: 'llm.pipeline.attempts_loop',
                                          handled:   true)
                assembler&.provider_failover_pending!(from: lane) if assembler.respond_to?(:provider_failover_pending!)

                classify_and_accumulate_exclusions(error: e, lane: lane, payload: routing_payload)
              end
            end

            err = Legion::LLM::Errors::EscalationExhausted.new(
              attempts:    total_attempts,
              tried_lanes: routing_payload[:tried_lanes],
              last_error:  last_error
            )
            log.warn("[llm][executor] action=escalation_exhausted_loop_complete attempts=#{total_attempts} " \
                     "tried=#{routing_payload[:tried_lanes].size}")
            emit_error_audit(err, status: 'escalation_exhausted')
            raise err
          end

          # Select the next lane to dispatch to.
          # On the first attempt (attempt_idx == 0): prefer the Inventory lane matching the provider/model
          # already resolved by step_routing (preserves routing phase resolution). Falls through to
          # request_lane if no specific lane exists.
          # On subsequent attempts: delegate entirely to request_lane (the new SSOT, per G26/SSOT design).
          def select_next_lane(routing_payload:, attempt_idx:, **)
            if attempt_idx.zero? && @resolved_provider && @resolved_model
              # First attempt: look up the Inventory lane for the routing-resolved (provider, instance, model).
              # If found and not already tried/blocked, use it. Otherwise fall through to request_lane.
              provider_lanes = Legion::LLM::Inventory.lanes_for(
                provider: @resolved_provider, instance: @resolved_instance
              )
              preferred = provider_lanes.find do |l|
                l[:model] == @resolved_model &&
                  !routing_payload[:tried_lanes].include?(l[:id]) &&
                  l[:lane_weight].to_i.positive?
              end
              return preferred if preferred
            end
            Legion::LLM::Router.request_lane(**routing_payload)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.select_next_lane')
            Legion::LLM::Router.request_lane(**routing_payload)
          end

          def step_provider_call_stream(&block)
            if ssot_v3_inventory_active?
              run_provider_call_ssot_v3_stream(&block)
              return
            end

            if pipeline_escalation_enabled?
              run_provider_call_with_attempts(routing_payload: build_routing_payload_from_resolved,
                                              stream_block:    block)
              return
            end

            execute_provider_request_stream(&block)
          rescue Legion::LLM::AuthError, Faraday::UnauthorizedError, Faraday::ForbiddenError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.auth',
                             provider: @resolved_provider, model: @resolved_model)
            report_provider_failure(e, status: 'auth_failed')
            raise e.is_a?(Legion::LLM::AuthError) ? e : Legion::LLM::AuthError.new(e.message)
          rescue Legion::LLM::ContextOverflow => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.context_overflow',
                             provider: @resolved_provider, model: @resolved_model)
            emit_error_audit(e, status: 'context_overflow')
            raise
          rescue Legion::LLM::RateLimitError, Faraday::TooManyRequestsError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.rate_limit',
                             provider: @resolved_provider, model: @resolved_model)
            report_provider_failure(e, status: 'rate_limited')
            raise e.is_a?(Legion::LLM::RateLimitError) ? e : Legion::LLM::RateLimitError.new(e.message, retry_after: extract_retry_after(e))
          rescue Legion::LLM::ProviderDown, Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.provider_down',
                             provider: @resolved_provider, model: @resolved_model)
            report_provider_failure(e, status: 'provider_down')
            raise e.is_a?(Legion::LLM::ProviderDown) ? e : Legion::LLM::ProviderDown.new(e.message)
          rescue Legion::LLM::ProviderError, Faraday::ServerError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.provider_error',
                             provider: @resolved_provider, model: @resolved_model)
            report_provider_failure(e, status: 'provider_error')
            raise e.is_a?(Legion::LLM::ProviderError) ? e : Legion::LLM::ProviderError.new(e.message)
          rescue StandardError => e
            raise if client_stream_error?(e)

            report_provider_failure(e, status: 'provider_error')
            raise
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
