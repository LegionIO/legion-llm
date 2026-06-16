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
            if escalation
              run_provider_call_with_escalation
            else
              run_provider_call_single
            end
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

          def run_provider_call_with_escalation(stream_block: nil, responses_body: nil, responses_stream: false)
            @escalation_chain ||= build_default_escalation_chain
            chain = @escalation_chain
            threshold = pipeline_escalation_quality_threshold
            quality_check = @request.extra[:quality_check]
            succeeded = false
            tried = []
            @last_escalation_error = nil
            log.debug "[llm][executor] action=escalation.enter chain_size=#{chain.size} threshold=#{threshold} max_attempts=#{chain.max_attempts}"

            primary_tier = @escalation_chain.primary&.tier

            if chain.empty?
              err = routing_empty_chain_error
              log.warn "[llm][escalation] action=empty_chain reason=#{err.class.name}"
              emit_error_audit(err, status: 'no_available_provider')
              raise err
            end

            chain.each do |resolution|
              next if tried.any? { |t| t[:provider] == resolution.provider && t[:instance] == resolution.instance && t[:model] == resolution.model }

              if skip_open_circuits? && circuit_open?(resolution)
                log.info "[llm][escalation] action=skip_open_circuit provider=#{resolution.provider} " \
                         "instance=#{resolution.instance} model=#{resolution.model}"
                @escalation_history << escalation_attempt_hash(
                  resolution,
                  outcome:     :skipped_open_circuit,
                  failures:    ['circuit_open'],
                  duration_ms: 0
                )
                next
              end

              succeeded = run_escalation_resolution(resolution, threshold, quality_check, tried, primary_tier,
                                                    stream_block:     stream_block,
                                                    responses_body:   responses_body,
                                                    responses_stream: responses_stream)
              break if succeeded
            end
            return if succeeded
            raise @last_escalation_error if chain.size <= 1 && @last_escalation_error

            log.warn "[llm][escalation] action=exhausted attempts=#{@escalation_history.size} chain_size=#{chain.size}"
            emit_error_audit(
              EscalationExhausted.new("All #{@escalation_history.size} attempts failed"),
              status: 'escalation_exhausted'
            )
            raise EscalationExhausted, "All #{@escalation_history.size} escalation attempts failed"
          end

          def run_escalation_resolution(resolution, threshold, quality_check, tried, primary_tier, stream_block: nil,
                                        responses_body: nil, responses_stream: false)
            move_type = escalation_move_type(resolution, tried, primary_tier)
            prev_provider = @resolved_provider
            prev_tier = @resolved_tier
            log_escalation_attempt(resolution, move_type, tried.size + 1)
            if move_type == :escalation && %i[local fleet vllm].include?(prev_tier) && %i[cloud frontier].include?(resolution.tier)
              log.warn "[llm][escalation] action=tier_upgrade from_tier=#{prev_tier} " \
                       "from_provider=#{prev_provider} to_tier=#{resolution.tier} " \
                       "to_provider=#{resolution.provider} to_model=#{resolution.model}"
            end

            start_time = Time.now
            prev_resolution = if stream_block && tried.any?
                                Legion::LLM::Router::Resolution.new(
                                  tier: prev_tier, provider: prev_provider,
                                  instance: @resolved_instance, model: @resolved_model
                                )
                              end
            @resolved_provider = resolution.provider
            @resolved_instance = resolution.instance
            @resolved_model = resolution.model
            @resolved_tier = resolution.tier
            @resolved_offering_id = resolution.offering_id
            @resolved_offering_metadata = resolution.offering_metadata
            notify_stream_provider_switched(prev_resolution, resolution) if prev_resolution
            succeeded = attempt_escalation(resolution, threshold, quality_check, start_time,
                                           stream_block:     stream_block,
                                           responses_body:   responses_body,
                                           responses_stream: responses_stream)
            tried << { provider: resolution.provider, instance: resolution.instance, model: resolution.model } unless succeeded
            succeeded
          rescue Legion::LLM::AuthError, Legion::LLM::PrivacyModeError => e
            tried << { provider: resolution.provider, instance: resolution.instance, model: resolution.model }
            record_escalation_failure(e, resolution, start_time,
                                      outcome:   :auth_error,
                                      operation: 'llm.pipeline.escalation_attempt.auth',
                                      handled:   true)
            false
          rescue Legion::LLM::ContextOverflow => e
            tried << { provider: resolution.provider, instance: resolution.instance, model: resolution.model }
            record_escalation_failure(e, resolution, start_time,
                                      outcome:   :context_overflow,
                                      operation: 'llm.pipeline.escalation_attempt.context_overflow',
                                      handled:   true)
            log.warn "[llm][escalation] context_overflow provider=#{resolution.provider} " \
                     "model=#{resolution.model} — skipping same-tier, seeking larger context window"
            skip_same_tier!(resolution, tried)
            false
          rescue Legion::LLM::RateLimitError => e
            tried << { provider: resolution.provider, instance: resolution.instance, model: resolution.model }
            record_escalation_failure(e, resolution, start_time,
                                      outcome:   :rate_limited,
                                      operation: 'llm.pipeline.escalation_attempt.rate_limit',
                                      handled:   true)
            false
          rescue StandardError => e
            if client_stream_error?(e)
              log.warn "[llm][escalation] action=client_stream_error error=#{e.class}: #{e.message} " \
                       "provider=#{resolution.provider} model=#{resolution.model}"
              raise
            end

            notify_stream_provider_failed(e, resolution) if stream_block
            skip_all_provider_model_instances!(resolution, tried)
            record_escalation_failure(e, resolution, start_time,
                                      outcome:   :error,
                                      operation: 'llm.pipeline.escalation_attempt')
            false
          end

          def escalation_move_type(resolution, tried, primary_tier)
            return :primary if tried.empty?
            return :lateral if resolution.tier == primary_tier

            :escalation
          end

          def log_escalation_attempt(resolution, move_type, attempt)
            message = "[llm][escalation] action=attempt move=#{move_type} provider=#{resolution.provider} " \
                      "model=#{resolution.model} tier=#{resolution.tier} attempt=#{attempt}"
            if move_type == :primary
              log.info message
            else
              log.warn "#{message} #{escalation_previous_failure_summary}"
            end
          end

          def escalation_previous_failure_summary
            error = @last_escalation_error
            return "previous_error=#{error.class.name} previous_message=#{error.message.to_s[0, 200]}" if error

            previous = @escalation_history.last
            return 'previous_error=unknown' unless previous

            failures = Array(previous[:failures]).join(',')
            "previous_outcome=#{previous[:outcome]} previous_failures=#{failures}"
          end

          def attempt_escalation(resolution, threshold, quality_check, start_time, stream_block: nil,
                                 responses_body: nil, responses_stream: false)
            @current_escalation_context = {
              attempt:      @escalation_history.size + 1,
              max_attempts: @escalation_chain&.max_attempts
            }.compact
            if responses_body && resolved_provider_supports_responses?
              execute_provider_request_responses(body: responses_body, stream: responses_stream, &stream_block)
              result = Legion::LLM::Quality::Checker::QualityResult.new(passed: true, failures: [])
            elsif stream_block
              execute_provider_request_stream(&stream_block)
              # NOTE: Streaming escalation attempts always pass quality check (B-05).
              # Quality-checking a stream in-flight is not supported; the first provider
              # in the chain wins for streaming requests. If quality gating is required
              # for streaming, handle it at the caller level.
              result = Legion::LLM::Quality::Checker::QualityResult.new(passed: true, failures: [])
            else
              execute_provider_request
              result = Legion::LLM::Quality::Checker.check(@raw_response, quality_threshold: threshold,
                                                                          quality_check:     quality_check)
            end
            duration_ms = ((Time.now - start_time) * 1000).round
            outcome = result.passed ? :success : :quality_failure
            log.debug "[llm][escalation] action=attempt_result provider=#{resolution.provider} model=#{resolution.model} outcome=#{outcome} duration_ms=#{duration_ms}"
            @timeline.record(
              category: :provider, key: 'escalation:attempt', direction: :internal,
              detail: "attempt #{@escalation_history.size + 1}: #{resolution.provider}:#{resolution.model} => #{outcome}",
              from: 'pipeline', to: "provider:#{resolution.provider}"
            )
            @escalation_history << escalation_attempt_hash(
              resolution,
              outcome:     outcome,
              failures:    result.passed ? [] : result.failures,
              duration_ms: duration_ms
            )
            report_escalation_quality_failure(resolution, result) unless result.passed
            emit_escalation_attempt_metering(
              provider:    resolution.provider,
              model:       resolution.model,
              duration_ms: duration_ms,
              attempt:     @escalation_history.size
            )
            emit_escalation_attempt_audit(
              provider:    resolution.provider,
              model:       resolution.model,
              outcome:     outcome,
              duration_ms: duration_ms,
              attempt:     @escalation_history.size
            )
            result.passed
          ensure
            @current_escalation_context = nil
          end

          def report_escalation_quality_failure(resolution, result)
            log.warn "[llm][escalation] quality_failure provider=#{resolution.provider} " \
                     "model=#{resolution.model} failures=#{Array(result.failures).join(',')}"
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.escalation_attempt.health_report',
                                provider: resolution.provider, model: resolution.model)
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
            elsif authentication_error?(err) || config_error?(err)
              Legion::LLM::Router.health_tracker.deny_model(
                provider: resolution.provider,
                model:    resolution.model,
                instance: resolution.instance,
                reason:   err.message
              )
              Legion::LLM::Router.health_tracker.trip_circuit(
                provider: resolution.provider,
                instance: resolution.instance,
                reason:   err.message
              )
            elsif !context_overflow_error?(err)
              Legion::LLM::Router.health_tracker.report(provider: resolution.provider, instance: resolution.instance,
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

          def build_default_escalation_chain
            chain = Legion::LLM::Router.build_escalation_chain(
              provider:              @resolved_provider,
              model:                 @resolved_model,
              tier:                  @resolved_tier,
              instance:              @resolved_instance,
              max_attempts:          pipeline_escalation_max_attempts,
              estimated_tokens:      estimate_request_tokens,
              required_capabilities: chain_required_capabilities
            )
            log.debug "[llm][escalation] action=chain_built size=#{chain.size} max_attempts=#{chain.max_attempts} " \
                      "primary=#{@resolved_provider}:#{@resolved_model} fallbacks=#{chain.size - 1}"
            chain
          end

          # Determine the appropriate typed error when the escalation chain is empty.
          # Uses the last rejection reasons from availability filtering to distinguish
          # between "too early" (prerequisites not yet confirmed) and "failed dependency"
          # (no provider can satisfy the requirements).
          def routing_empty_chain_error
            reasons = Legion::LLM::Router::Availability.last_rejection_reasons
            if reasons.include?(:capability_unconfirmed)
              RoutingTooEarly.new
            elsif reasons.any?
              RoutingFailedDependency.new
            else
              EscalationExhausted.new('No available providers after routing availability filtering')
            end
          end

          def skip_same_tier!(failed_resolution, tried)
            chain = @escalation_chain
            return unless chain.respond_to?(:each)

            chain.each do |r|
              next if r.tier != failed_resolution.tier
              next if tried.any? { |t| t[:provider] == r.provider && t[:instance] == r.instance && t[:model] == r.model }

              log.debug "[llm][escalation] action=skip_same_tier provider=#{r.provider} model=#{r.model} tier=#{r.tier} reason=context_overflow"
              tried << { provider: r.provider, instance: r.instance, model: r.model }
            end
          end

          def skip_all_provider_model_instances!(failed_resolution, tried)
            chain = @escalation_chain
            return unless chain.respond_to?(:each)

            chain.each do |r|
              next if r.provider != failed_resolution.provider || r.model != failed_resolution.model
              next if tried.any? { |t| t[:provider] == r.provider && t[:instance] == r.instance && t[:model] == r.model }

              log.warn "[llm][escalation] action=skip_provider_model provider=#{r.provider} model=#{r.model} " \
                       "instance=#{r.instance} reason=provider_error"
              tried << { provider: r.provider, instance: r.instance, model: r.model }
            end
          end

          def escalation_attempt_hash(resolution, outcome:, failures:, duration_ms:)
            attempt = { model: resolution.model, provider: resolution.provider, tier: resolution.tier,
                        outcome: outcome, failures: failures, duration_ms: duration_ms }
            attempt[:offering_id] = resolution.offering_id if resolution.offering_id
            attempt[:offering_metadata] = resolution.offering_metadata unless resolution.offering_metadata.empty?
            attempt
          end

          def pipeline_escalation_enabled?
            esc = Legion::Settings[:llm].dig(:routing, :escalation) || {}
            esc[:enabled] == true && esc[:pipeline_enabled] == true
          end

          def pipeline_escalation_max_attempts
            esc = Legion::Settings[:llm].dig(:routing, :escalation) || {}
            esc[:max_attempts] || 3
          end

          def pipeline_escalation_quality_threshold
            esc = Legion::Settings[:llm].dig(:routing, :escalation) || {}
            esc[:quality_threshold] || 50
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
            return if client_stream_error?(error)

            if authentication_error?(error) || config_error?(error)
              Legion::LLM::Router.health_tracker.deny_model(
                provider: provider,
                model:    model,
                instance: instance,
                reason:   error.message
              )
              Legion::LLM::Router.health_tracker.trip_circuit(
                provider: provider,
                instance: instance,
                reason:   error.message
              )
              return
            end

            Legion::LLM::Router.health_tracker.report(
              provider: provider, instance: instance,
              offering_id: offering_id, signal: :error, value: 1,
              metadata: { reason: error.class.name, message: error.message.to_s[0, 500], model: model }
            )
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.report_provider_failure')
          end

          def report_provider_health(signal, duration_ms, metadata: {})
            return unless defined?(Legion::LLM::Router) && Legion::LLM::Router.routing_enabled?

            Legion::LLM::Router.health_tracker.report(provider: @resolved_provider, instance: @resolved_instance,
                                                      offering_id: @resolved_offering_id,
                                                      signal: signal, value: 1, metadata: metadata.merge(duration_ms: duration_ms))
            Legion::LLM::Router.health_tracker.report(provider: @resolved_provider, instance: @resolved_instance,
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

          def notify_stream_provider_failed(error, resolution)
            @stream_observer&.provider_failed(error: error, resolution: resolution)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true,
                             operation: 'llm.pipeline.stream_observer.provider_failed')
          end

          def notify_stream_provider_switched(from, to)
            return unless from

            @stream_observer&.provider_switched(from: from, to: to)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true,
                             operation: 'llm.pipeline.stream_observer.provider_switched')
          end

          def skip_open_circuits?
            esc = Legion::Settings[:llm].dig(:routing, :escalation) || {}
            esc[:skip_open_circuits] != false
          end

          def circuit_open?(resolution)
            Legion::LLM::Router.health_tracker.circuit_state(resolution.provider, instance: resolution.instance) == :open
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.escalation.circuit_check')
            false
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
              err.class.name.to_s.include?('ContextLength')
          end

          # Detect client-side stream errors (disconnects, broken pipes, socket timeouts)
          # that originate from writing back to the HTTP client, not from the provider itself.
          def client_stream_error?(err)
            name = err.class.name.to_s
            msg  = err.message.to_s
            name.include?('Puma::ConnectionError') ||
              name.include?('Errno::EPIPE') ||
              (name.include?('IOError') && msg.include?('closed')) ||
              (name.include?('IOError') && msg.include?('already closed')) ||
              name.include?('EOFError') ||
              name.include?('Errno::ECONNRESET') ||
              name.include?('Errno::ECONNABORTED')
          end

          def step_provider_call_stream(&block)
            if pipeline_escalation_enabled?
              run_provider_call_with_escalation(stream_block: block)
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

          def execute_provider_request_responses(body:, stream:, &)
            @timestamps[:provider_start] = Time.now
            @timeline.record(
              category: :provider, key: 'provider:request_sent',
              exchange_id: @exchange_id, direction: :outbound,
              detail: "responses from #{@resolved_provider}",
              from: 'pipeline', to: "provider:#{@resolved_provider}"
            )

            raise Legion::LLM::ProviderError, "Native provider not registered: #{@resolved_provider}" unless use_native_dispatch?(@resolved_provider)

            result = execute_native_responses_tool_loop(body: body, stream: stream, &)
            merge_response_offering_metadata(result.metadata) if result.respond_to?(:metadata)
            @raw_response = result

            @timestamps[:provider_end] = Time.now
            record_provider_response
          end
        end
      end
    end
  end
end
