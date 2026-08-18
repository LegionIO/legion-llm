# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'publisher_identity'
require_relative 'metering/usage'
require_relative 'inference/context_accounting'
require_relative 'inference/request'
require_relative 'inference/response'
require_relative 'inference/profile'
require_relative 'inference/timeline'
require_relative 'inference/tracing'
require_relative 'inference/steps'
require_relative 'inference/steps/gut_check'
require_relative 'inference/tool_dispatcher'
require_relative 'inference/audit_publisher'
require_relative 'inference/enrichment_injector'
require_relative 'inference/gaia_caller'
require_relative 'inference/executor'

module Legion
  module LLM
    module Inference
      extend Legion::Logging::Helper

      FRAMEWORK_KEYS = %i[request_id source timestamp datetime task_id parent_id master_id
                          check_subtask generate_task catch_exceptions worker_id principal_id
                          principal_type caller].freeze

      module_function

      # Public inference entry points — these are the methods delegated from Legion::LLM

      def chat(model: nil, provider: nil, intent: nil, tier: nil, escalate: nil,
               max_escalations: nil, quality_check: nil, message: nil, **kwargs, &)
        started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        log_inference_request(
          request_type:       :chat,
          requested_model:    model,
          requested_provider: provider,
          intent:             intent,
          tier:               tier,
          message:            message,
          kwargs:             kwargs
        )

        result = if defined?(Legion::Telemetry::OpenInference)
                   Legion::Telemetry::OpenInference.llm_span(
                     model:    (model || Legion::Settings[:llm][:default_model]).to_s,
                     provider: provider&.to_s,
                     input:    message
                   ) do |_span|
                     dispatch_chat(model: model, provider: provider, intent: intent, tier: tier, escalate: escalate,
                                   max_escalations: max_escalations, quality_check: quality_check, message: message, **kwargs, &)
                   end
                 else
                   dispatch_chat(model: model, provider: provider, intent: intent, tier: tier,
                                 escalate: escalate, max_escalations: max_escalations,
                                 quality_check: quality_check, message: message, **kwargs, &)
                 end

        log_inference_response(
          request_type:       :chat,
          requested_model:    model,
          requested_provider: provider,
          result:             result,
          duration_ms:        elapsed_ms_since(started_at)
        )
        result
      rescue StandardError => e
        log_inference_error(
          request_type:       :chat,
          requested_model:    model,
          requested_provider: provider,
          error:              e,
          duration_ms:        elapsed_ms_since(started_at)
        )
        raise
      end

      def ask(message:, model: nil, provider: nil, intent: nil, tier: nil,
              context: {}, identity: nil, &)
        started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        log_inference_request(
          request_type:       :ask,
          requested_model:    model,
          requested_provider: provider,
          intent:             intent,
          tier:               tier,
          message:            message,
          kwargs:             { context: context, identity: identity }
        )

        if Call::DaemonClient.available?
          result = daemon_ask(message: message, model: model, provider: provider,
                              context: context, tier: tier, identity: identity)
          if result
            log_inference_response(
              request_type:       :ask,
              requested_model:    model,
              requested_provider: provider,
              result:             result,
              duration_ms:        elapsed_ms_since(started_at)
            )
            return result
          end
        end

        result = ask_direct(message: message, model: model, provider: provider,
                            intent: intent, tier: tier, &)
        log_inference_response(
          request_type:       :ask,
          requested_model:    model,
          requested_provider: provider,
          result:             result,
          duration_ms:        elapsed_ms_since(started_at)
        )
        result
      rescue StandardError => e
        log_inference_error(
          request_type:       :ask,
          requested_model:    model,
          requested_provider: provider,
          error:              e,
          duration_ms:        elapsed_ms_since(started_at)
        )
        raise
      end

      # rubocop:disable Legion/Framework/NoDirectDispatch
      # chat_direct is a deprecated shim per CHANGELOG 0.12.16 that routes
      # through the governed pipeline; see Legion::LLM::Deprecation.warn_once.
      def chat_direct(model: nil, provider: nil, intent: nil, tier: nil, escalate: nil,
                      max_escalations: nil, quality_check: nil, message: nil, **, &)
        Legion::LLM::Deprecation.warn_once(:chat_direct, replacement: 'Legion::LLM.chat')

        if Thread.current[:legion_llm_in_pipeline] || !pipeline_enabled? || !message
          return chat_direct_raw(model: model, provider: provider, intent: intent, tier: tier,
                                 escalate: escalate, max_escalations: max_escalations,
                                 quality_check: quality_check, message: message, **, &)
        end

        chat_direct_governed(model: model, provider: provider, intent: intent, tier: tier,
                             escalate: escalate, max_escalations: max_escalations,
                             quality_check: quality_check, message: message, **, &)
      end
      # rubocop:enable Legion/Framework/NoDirectDispatch

      def chat_direct_governed(model: nil, provider: nil, intent: nil, tier: nil, escalate: nil,
                               max_escalations: nil, quality_check: nil, message: nil, **kwargs, &)
        log.debug(
          "[llm][inference] chat_direct_governed.enter model=#{model} provider=#{provider} " \
          "intent=#{intent} tier=#{tier} message_present=#{!message.nil?}"
        )

        assert_external_allowed! if effective_tier_is_external?(tier, provider)

        caller_hash = kwargs.delete(:caller) || { requested_by: { type: :system, identity: 'legion:internal:chat_direct' } }
        cache_opt = kwargs.delete(:cache) { true }
        temperature = kwargs.delete(:temperature)
        kwargs.delete(:urgency)

        # SSOT v3 §20.1: select first, then probe the response cache by the exact
        # Selection identity — before any callable acquisition. Legacy pre-routing
        # cache remains as the fallback when the SSOT inventory path is inactive.
        cache_key = nil
        ssot_cache = ssot_response_cache(message: message, model: model, provider: provider,
                                         tier: tier, temperature: temperature, cache_opt: cache_opt,
                                         shape: response_cache_shape(kwargs))
        if ssot_cache
          return ssot_cache[:response] if ssot_cache[:hit]

          cache_key = ssot_cache[:key]
        elsif cacheable?(cache_opt, temperature, message)
          cache_key = build_cache_key(model, provider, message, temperature)
          cached = Cache.get(cache_key)
          if cached
            log.debug '[llm][inference] chat_direct_governed cache=hit path=legacy'
            cached_response = cached.dup
            cached_response[:meta] = (cached_response[:meta] || {}).merge(cached: true)
            return cached_response
          end
        end

        # SSOT v3: no default provider/model and no legacy fallback. An
        # unconstrained request (no provider/model/tier pin) is a valid
        # unconstrained SSOT selection — next_lane ranks all eligible lanes.
        # There is one engine (Prompt.dispatch -> Executor -> RoutingSession).
        result = Prompt.dispatch(
          message,
          intent: intent, tier: tier, provider: provider, model: model,
          escalate: escalate, max_escalations: max_escalations,
          quality_check: quality_check, caller: caller_hash,
          temperature: temperature, **kwargs.except(:messages)
        )

        if cache_key && result.is_a?(Hash)
          ttl = Legion::Settings[:llm][:prompt_caching][:response_cache][:ttl_seconds]
          Cache.set(cache_key, result, ttl: ttl)
        end

        log.debug("[llm][inference] chat_direct_governed.exit result_class=#{result.class}")
        result
      end

      def chat_direct_raw(model: nil, provider: nil, intent: nil, tier: nil, escalate: nil,
                          max_escalations: nil, quality_check: nil, message: nil, **kwargs, &)
        log.debug(
          "[llm][inference] chat_direct_raw.enter model=#{model} provider=#{provider} intent=#{intent} " \
          "tier=#{tier} escalate=#{escalate} message_present=#{!message.nil?} kwargs=#{kwargs.keys.sort}"
        )
        cache_opt = kwargs.delete(:cache) { true }
        temperature = kwargs.delete(:temperature)

        escalate = escalation_enabled? if escalate.nil?

        # SSOT v3 §20.1: select first, then probe the response cache by the exact
        # Selection identity — before any callable acquisition. Legacy pre-routing
        # cache remains as the fallback when the SSOT inventory path is inactive.
        cache_key = nil
        ssot_cache = ssot_response_cache(message: message, model: model, provider: provider,
                                         tier: tier, temperature: temperature, cache_opt: cache_opt,
                                         shape: response_cache_shape(kwargs))
        if ssot_cache
          return ssot_cache[:response] if ssot_cache[:hit]

          cache_key = ssot_cache[:key]
        elsif cacheable?(cache_opt, temperature, message)
          cache_key = build_cache_key(model, provider, message, temperature)
          cached = Cache.get(cache_key)
          if cached
            log.debug '[llm][inference] chat_direct_raw cache=hit path=legacy'
            cached_response = cached.dup
            cached_response[:meta] = (cached_response[:meta] || {}).merge(cached: true)
            return cached_response
          end
        end

        urgency = kwargs.delete(:urgency) { :normal }
        deferred = try_defer(intent: intent, urgency: urgency, model: model, provider: provider, message: message, **kwargs)
        return deferred if deferred

        log.debug(
          "[llm][inference] chat_direct_raw.dispatch model=#{model} provider=#{provider} " \
          "escalate=#{escalate} message_present=#{!message.nil?}"
        )
        # SSOT v3 single engine: retry/failover is inherent to the RoutingSession
        # loop, so there is no separate escalation chain and no chat_single legacy
        # selector — both collapse to one Prompt.dispatch -> Executor call.
        result = Prompt.dispatch(
          message,
          intent: intent, tier: tier, provider: provider, model: model,
          escalate: escalate, max_escalations: max_escalations,
          quality_check: quality_check, caller: kwargs[:caller],
          temperature: temperature, **kwargs.except(:messages, :caller), &
        )
        log.debug("[llm][inference] chat_direct_raw.exit result_class=#{result.class} result_nil=#{result.nil?}")

        if cache_key && result.is_a?(Hash)
          ttl = Legion::Settings[:llm][:prompt_caching][:response_cache][:ttl_seconds]
          Cache.set(cache_key, result, ttl: ttl)
        end

        result
      end

      def log_inference_request(request_type:, requested_model:, requested_provider:, intent:, tier:, message:, kwargs:)
        input = inference_input_payload(message: message, messages: kwargs[:messages])
        parts = [
          '[llm][inference] request',
          "type=#{request_type}",
          "input_length=#{inference_text_length(input)}",
          "input=#{input.inspect}"
        ]
        parts << "requested_provider=#{requested_provider}" if requested_provider
        parts << "requested_model=#{requested_model}" if requested_model
        parts << "intent=#{intent}" if intent
        parts << "tier=#{tier}" if tier
        parts << "caller=#{caller_descriptor(kwargs[:caller])}" if kwargs[:caller]
        parts << "conversation_id=#{kwargs[:conversation_id]}" if kwargs[:conversation_id]
        parts << "request_id=#{kwargs[:request_id]}" if kwargs[:request_id]
        parts << "tools=#{Array(kwargs[:tools]).size}" if kwargs.key?(:tools)
        parts << 'stream=true' if kwargs[:stream]
        log.info(parts.join(' '))
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.inference.log_request')
      end

      def log_inference_response(request_type:, requested_model:, requested_provider:, result:, duration_ms:)
        details = inference_response_details(result, requested_model: requested_model, requested_provider: requested_provider)
        parts = [
          '[llm][inference] response',
          "type=#{request_type}",
          'status=ok',
          "duration_ms=#{duration_ms}",
          "result_class=#{result.class}",
          "output_length=#{inference_text_length(details[:output])}",
          "output=#{details[:output].inspect}"
        ]
        parts << "provider=#{details[:provider]}" if details[:provider]
        parts << "model=#{details[:model]}" if details[:model]
        parts << "input_tokens=#{details[:input_tokens]}" unless details[:input_tokens].nil?
        parts << "output_tokens=#{details[:output_tokens]}" unless details[:output_tokens].nil?
        parts << "stop_reason=#{details[:stop_reason]}" if details[:stop_reason]
        parts << "tool_calls=#{details[:tool_calls]}" unless details[:tool_calls].nil?
        log.info(parts.join(' '))
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.inference.log_response')
      end

      def log_inference_error(request_type:, requested_model:, requested_provider:, error:, duration_ms:)
        parts = [
          '[llm][inference] response',
          "type=#{request_type}",
          'status=error',
          "duration_ms=#{duration_ms}",
          "error_class=#{error.class}",
          "error=#{error.message.inspect}"
        ]
        parts << "requested_provider=#{requested_provider}" if requested_provider
        parts << "requested_model=#{requested_model}" if requested_model
        log.error(parts.join(' '))
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.inference.log_error')
      end

      def elapsed_ms_since(started_at)
        ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      end

      def inference_input_payload(message:, messages:)
        return messages unless messages.nil?

        message
      end

      def inference_text_length(payload)
        case payload
        when Array
          payload.sum { |item| inference_text_length(item) }
        when Hash
          return payload[:content].to_s.length if payload.key?(:content)
          return payload['content'].to_s.length if payload.key?('content')

          payload.values.sum { |item| inference_text_length(item) }
        when nil
          0
        else
          payload.to_s.length
        end
      end

      def inference_response_details(result, requested_model:, requested_provider:)
        return pipeline_response_details(result, requested_model: requested_model, requested_provider: requested_provider) if result.is_a?(Legion::LLM::Inference::Response)
        return hash_response_details(result, requested_model: requested_model, requested_provider: requested_provider) if result.is_a?(Hash)

        object_response_details(result, requested_model: requested_model, requested_provider: requested_provider)
      end

      def pipeline_response_details(result, requested_model:, requested_provider:)
        message = result.message
        tokens = result.tokens
        {
          output:        message.is_a?(Hash) ? (message[:content] || message['content']) : message.to_s,
          provider:      result.routing[:provider] || result.routing['provider'] || requested_provider,
          model:         result.routing[:model] || result.routing['model'] || requested_model,
          input_tokens:  inference_token_value(tokens, :input),
          output_tokens: inference_token_value(tokens, :output),
          stop_reason:   result.stop[:reason] || result.stop['reason'],
          tool_calls:    Array(result.tools).size
        }
      end

      def hash_response_details(result, requested_model:, requested_provider:)
        meta = result[:meta] || result['meta'] || {}
        {
          output:        result[:response] || result['response'] || result[:content] || result['content'] || result.dig(:message, :content) || result.to_s,
          provider:      result[:provider] || result['provider'] || meta[:provider] || meta['provider'] || requested_provider,
          model:         result[:model] || result['model'] || meta[:model] || meta['model'] || requested_model,
          input_tokens:  result[:input_tokens] || result['input_tokens'] || meta[:tokens_in] || meta['tokens_in'],
          output_tokens: result[:output_tokens] || result['output_tokens'] || meta[:tokens_out] || meta['tokens_out'],
          stop_reason:   result[:stop_reason] || result['stop_reason'] || result.dig(:stop, :reason) || result.dig('stop', 'reason'),
          tool_calls:    Array(result[:tool_calls] || result['tool_calls'] || result[:tools] || result['tools']).size
        }
      end

      def object_response_details(result, requested_model:, requested_provider:)
        tool_calls = safe_inference_value(result, :tool_calls)
        {
          output:        safe_inference_value(result, :content) || result.to_s,
          provider:      requested_provider,
          model:         safe_inference_value(result, :model_id)&.to_s || requested_model,
          input_tokens:  safe_inference_value(result, :input_tokens),
          output_tokens: safe_inference_value(result, :output_tokens),
          stop_reason:   safe_inference_value(result, :stop_reason),
          tool_calls:    tool_calls.nil? ? nil : Array(tool_calls).size
        }
      end

      def safe_inference_value(object, method_name)
        return nil unless object.methods.include?(method_name) || object.private_methods.include?(method_name)

        object.public_send(method_name)
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.inference.safe_value', method_name: method_name)
        nil
      end

      def inference_token_value(tokens, key)
        return nil if tokens.nil?
        return tokens[key] || tokens[key.to_s] if tokens.is_a?(Hash)

        method_name = { input: :input_tokens, output: :output_tokens, total: :total_tokens }[key]
        return tokens.public_send(method_name) if method_name && tokens.respond_to?(method_name)

        nil
      end

      def caller_descriptor(caller_context)
        return caller_context unless caller_context.is_a?(Hash)

        source = caller_context[:source] || caller_context['source']
        path = caller_context[:path] || caller_context['path']
        return "#{source}:#{path}" if source && path
        return source.to_s if source

        caller_context.inspect
      end

      def dispatch_chat(model:, provider:, intent:, tier:, escalate:, max_escalations:, quality_check:, message:, **kwargs, &)
        log.debug(
          "[llm][inference] dispatch_chat.enter model=#{model} provider=#{provider} intent=#{intent} " \
          "tier=#{tier} escalate=#{escalate} max_escalations=#{max_escalations} " \
          "quality_check=#{quality_check} message_present=#{!message.nil?} kwargs=#{kwargs.keys.sort}"
        )
        if (message || kwargs[:messages]) && !block_given?
          return Prompt.dispatch(
            message || kwargs[:messages],
            intent: intent, tier: tier, provider: provider, model: model,
            escalate: escalate, max_escalations: max_escalations,
            quality_check: quality_check, **kwargs.except(:messages)
          )
        end

        if (message || kwargs[:messages]) && block_given?
          return chat_via_pipeline(model: model, provider: provider, intent: intent, tier: tier,
                                   message: message, escalate: escalate, max_escalations: max_escalations,
                                   quality_check: quality_check, **kwargs, &)
        end

        messages = message.is_a?(Array) ? message : [{ role: 'user', content: message.to_s }]
        resolved_model = model || Legion::Settings[:llm][:default_model]

        if defined?(Legion::LLM::Hooks)
          blocked = Legion::LLM::Hooks.run_before(messages: messages, model: resolved_model)
          return blocked[:response] || blocked_hook_response(blocked) if blocked
        end

        result = chat_direct_raw(model: model, provider: provider, intent: intent, tier: tier,
                                 escalate: escalate, max_escalations: max_escalations,
                                 quality_check: quality_check, message: message, **kwargs)

        if defined?(Legion::LLM::Hooks)
          blocked = Legion::LLM::Hooks.run_after(response: result, messages: messages, model: resolved_model)
          return blocked[:response] || blocked_hook_response(blocked) if blocked
        end

        result = apply_response_guards(result, kwargs) if response_guards_enabled? && result.is_a?(Hash)
        log.debug("[llm][inference] dispatch_chat.exit result_class=#{result.class} result_nil=#{result.nil?}")
        result
      end

      def pipeline_enabled?
        Legion::Settings[:llm][:pipeline_enabled] == true
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.inference.pipeline_enabled')
        false
      end

      def chat_via_pipeline(**, &block)
        request = Request.from_chat_args(**)
        executor = Executor.new(request)
        block ? executor.call_stream(&block) : executor.call
      end

      def daemon_ask(message:, model: nil, provider: nil, context: {}, tier: nil, **)
        result = Call::DaemonClient.chat(
          message: message, model: model, provider: provider,
          context: context, tier_preference: tier || :auto
        )

        case result[:status]
        when :immediate, :created
          result[:body]
        when :accepted
          Cache::Response.poll(result[:request_id])
        when :denied
          raise Legion::LLM::DaemonDeniedError, result.dig(:error, :message) || 'Access denied'
        when :rate_limited
          raise Legion::LLM::DaemonRateLimitedError, "Rate limited. Retry after #{result[:retry_after]}s"
        end
      end

      # rubocop:disable Legion/Framework/NoDirectDispatch
      # ask_direct is a deprecated shim. The previous body routed through
      # `chat_direct_raw`, an ungoverned path that bypasses metering/audit
      # — the same compliance gap that motivated the chat_direct/embed_direct/
      # structured_direct deprecation in 0.12.16. It now routes through the
      # governed pipeline via `chat_direct` and adapts the response to the
      # legacy `{status:, response:, meta:}` shape ask() callers expect.
      def ask_direct(message:, model: nil, provider: nil, intent: nil, tier: nil, &)
        Legion::LLM::Deprecation.warn_once(:ask_direct, replacement: 'Legion::LLM.ask')
        assert_external_allowed! if effective_tier_is_external?(tier, provider)

        result = chat_direct(
          model:    model,
          provider: provider,
          intent:   intent,
          tier:     tier,
          message:  message,
          &
        )

        return result if result.is_a?(Hash) && result[:deferred]
        return normalize_ask_direct_hash(result, fallback_model: model || Legion::Settings[:llm][:default_model]) if result.is_a?(Hash)

        response, resolved_model = resolve_ask_direct_response(result, message, model, &)

        {
          status:   :done,
          response: response.content,
          meta:     {
            tier:       :direct,
            model:      resolved_model,
            tokens_in:  response.respond_to?(:input_tokens) ? response.input_tokens : nil,
            tokens_out: response.respond_to?(:output_tokens) ? response.output_tokens : nil
          }
        }
      end
      # rubocop:enable Legion/Framework/NoDirectDispatch

      def direct_chat_session?(result)
        result.respond_to?(:ask) && result.respond_to?(:model) && !result.respond_to?(:content)
      end

      def resolve_ask_direct_response(result, message, requested_model, &)
        if direct_chat_session?(result)
          response = block_given? ? result.ask(message, &) : result.ask(message)
          return [response, result.model.to_s]
        end

        resolved_model = if result.respond_to?(:model_id) && result.model_id
                           result.model_id.to_s
                         else
                           (requested_model || Legion::Settings[:llm][:default_model]).to_s
                         end
        [result, resolved_model]
      end

      def normalize_ask_direct_hash(result, fallback_model:)
        meta = result[:meta].is_a?(Hash) ? result[:meta] : {}
        {
          status:   result[:status] || :done,
          response: result[:response] || result[:content],
          meta:     {
            tier:       meta[:tier] || :direct,
            model:      (meta[:model] || fallback_model).to_s,
            tokens_in:  meta[:tokens_in],
            tokens_out: meta[:tokens_out]
          }
        }
      end

      def try_defer(intent:, urgency:, model:, provider:, message:, **)
        return nil unless Scheduling.enabled? && Scheduling.should_defer?(intent: intent || :normal, urgency: urgency)
        return nil unless Legion::LLM::Scheduling::Batch.enabled?

        log.debug "[llm][inference] try_defer deferring intent=#{intent} urgency=#{urgency}"
        entry_id = Legion::LLM::Scheduling::Batch.enqueue(model: model, provider: provider, message: message, priority: urgency, **)
        { deferred: true, batch_id: entry_id, next_off_peak: Scheduling.next_off_peak.iso8601 }
      end

      def maybe_shadow_evaluate(response, messages, primary_model)
        return unless Quality::ShadowEval.enabled? && Quality::ShadowEval.should_sample?

        log.debug "[llm][inference] shadow_evaluate primary_model=#{primary_model}"
        Inference::Executor::ASYNC_THREAD_POOL.post do
          Quality::ShadowEval.evaluate(
            primary_response: { content: response.respond_to?(:content) ? response.content : response.to_s,
                                model: primary_model, usage: {} },
            messages:         messages
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.inference.shadow_eval')
        end
      end

      def publish_escalation_event(history, final_outcome, caller: nil)
        return if history.size <= 1

        first_attempt = history.first
        last_attempt = history.last

        event = {
          outcome:        final_outcome,
          attempts:       history.size,
          history:        history,
          # Flat fields for consumer compatibility
          from_provider:  first_attempt&.dig(:provider),
          from_instance:  first_attempt&.dig(:instance),
          from_model:     first_attempt&.dig(:model),
          to_provider:    last_attempt&.dig(:provider),
          to_instance:    last_attempt&.dig(:instance),
          to_model:       last_attempt&.dig(:model),
          reason:         ('provider_failover' if [:failure, 'failure', :error].include?(first_attempt&.dig(:outcome))),
          error_category: extract_error_category_from_attempt(first_attempt),
          attempt_no:     history.size,
          latency_ms:     history.sum { |a| (a[:duration_ms] || 0).to_i },
          caller:         caller || Legion::LLM::PublisherIdentity.caller_hash,
          timestamp:      Time.now.utc.iso8601
        }

        Legion::Events.emit('llm.escalation', **event) if defined?(Legion::Events) && Legion::Events.respond_to?(:emit)

        log.info "[llm][inference] escalation_event outcome=#{final_outcome} attempts=#{history.size}"

        Transport::Messages::EscalationEvent.new(event).publish if Legion::Settings.dig(:transport, :connected) == true
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.inference.publish_escalation_event', outcome: final_outcome)
        nil
      end

      def extract_error_category_from_attempt(attempt)
        return nil unless attempt.is_a?(Hash)

        failures = Array(attempt[:failures])
        return nil if failures.empty?

        first = failures.first
        if first.is_a?(Hash)
          first[:category]&.to_s || first[:error]&.to_s
        elsif first.is_a?(String)
          first
        else
          first.to_s
        end
      end

      def response_guards_enabled?
        Legion::Settings.dig(:llm, :response_guards, :enabled) == true
      end

      def blocked_hook_response(blocked)
        reason = blocked[:reason] || blocked['reason'] || blocked[:message] || blocked['message'] || 'request blocked by hook'
        { error: 'request_blocked', message: reason.to_s }
      end

      def apply_response_guards(result, kwargs)
        context = kwargs[:context]
        response_text = result[:response] || result[:content]
        guard_result = Hooks::ResponseGuard.guard_response(
          response: response_text, context: context
        )

        log.warn "[llm][inference] response_guard passed=#{guard_result[:passed]}" unless guard_result[:passed]

        result.merge(_guard_result: guard_result)
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.inference.apply_response_guards')
        result
      end

      def cacheable?(cache_opt, temperature, message)
        effective_temp = temperature.nil? ? Legion::Settings[:llm][:default_temperature] : temperature
        cache_opt != false && effective_temp.to_f.zero? && message && Cache.enabled?
      end

      def build_cache_key(model, provider, message, temperature)
        # SSOT v3 §20.1: no provider/model default injection in the key builder.
        # An omitted model/provider is an empty constraint, not a configured default.
        messages_arr = message.is_a?(Array) ? message : [{ role: 'user', content: message.to_s }]
        Cache.key(
          model:       model,
          provider:    provider,
          messages:    messages_arr,
          temperature: temperature
        )
      end

      # SSOT v3 §20.1 operation for the chat_direct response cache probe.
      RESPONSE_CACHE_OPERATION = :chat

      # SSOT v3 §20.1: select the exact lane through a per-request RoutingSession,
      # then probe the response cache keyed by that Selection — AFTER next_attempt
      # returns an AttemptContext but BEFORE any callable acquisition. A cache hit
      # therefore proves current policy/capability/context/availability eligibility
      # and reports the exact Selection identity while avoiding provider dispatch.
      # Returns:
      #   { hit: true,  response: <hash>, key: <str> } on hit,
      #   { hit: false, response: nil,   key: <str> } on miss (caller dispatches + stores),
      #   nil when the SSOT inventory path is inactive or the request is not
      #     cacheable (caller keeps the legacy pre-routing cache path).
      def ssot_response_cache(message:, model:, provider:, tier:, temperature:, cache_opt:, shape: {})
        return nil unless cacheable?(cache_opt, temperature, message)

        snapshot = Legion::Extensions::Llm::Inventory::Registry.snapshot
        return nil unless snapshot.generation.positive?

        request = ssot_cache_request(message: message, model: model, provider: provider,
                                     tier: tier, temperature: temperature, shape: shape)
        requirements = ssot_cache_requirements(request)
        return nil unless requirements

        session = Legion::LLM::Inference::RoutingSession.new(request: request, requirements: requirements)
        attempt = session.next_attempt(snapshot: snapshot)
        return nil if attempt.is_a?(Legion::Extensions::Llm::Routing::Rejection)

        key = ssot_cache_key_for(selection: attempt.selection, request: request, snapshot: snapshot)
        cached = Cache.get(key)
        return { hit: false, response: nil, key: key } unless cached

        response = cached.dup
        response[:meta] = (response[:meta] || {}).merge(
          cached:   true,
          provider: attempt.selection.provider_family,
          model:    attempt.selection.model,
          instance: attempt.selection.instance_id
        )
        log.debug "[llm][inference] action=ssot_response_cache cache=hit provider=#{attempt.selection.provider_family} model=#{attempt.selection.model}"
        { hit: true, response: response, key: key }
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'llm.inference.ssot_response_cache')
        nil
      end

      def ssot_cache_request(message:, model:, provider:, tier:, temperature:, shape:)
        args = { message: message, model: model, provider: provider }
        args[:tier] = tier if tier
        args[:system] = shape[:system] if shape[:system]
        args[:tools] = shape[:tools] if shape.key?(:tools)
        args[:tool_choice] = shape[:tool_choice] if shape[:tool_choice]
        args[:thinking] = shape[:thinking] if shape[:thinking]
        args[:response_format] = shape[:response_format] if shape[:response_format]
        args[:tokens] = shape[:tokens] if shape[:tokens]
        generation = (shape[:generation] || {}).dup
        generation[:temperature] = temperature unless temperature.nil?
        args[:generation] = generation unless generation.empty?
        Inference::Request.from_chat_args(**args)
      end

      # Mirror the executor's build_ssot_v3_routing_requirements so the probe
      # selection uses the exact same requirement inputs the dispatch will.
      def ssot_cache_requirements(request)
        required_caps = Legion::LLM::Router::RequiredCapabilities.call(
          request: request, operation: RESPONSE_CACHE_OPERATION
        )
        framing = request.routing_settings_snapshot&.input_framing_overhead_tokens || 0
        input_bound = Legion::LLM::Router::InputBound.call(
          operation:               RESPONSE_CACHE_OPERATION,
          messages:                request.messages,
          system:                  request.system,
          tools:                   request.tools,
          tool_choice:             request.tool_choice,
          thinking:                request.thinking,
          response_format:         request.response_format,
          framing_overhead_tokens: framing
        )
        Legion::LLM::Router::RequestRequirements.build(
          request:                request,
          operation:              RESPONSE_CACHE_OPERATION,
          required_capabilities:  required_caps,
          estimated_input_bound:  input_bound,
          required_output_tokens: 0
        )
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: 'llm.inference.ssot_cache_requirements')
        nil
      end

      def ssot_cache_key_for(selection:, request:, snapshot:)
        offering = snapshot.offering(offering_id: selection.offering_id)
        revision_evidence = offering.respond_to?(:model_revision_evidence) ? offering.model_revision_evidence : nil
        revision = if revision_evidence.respond_to?(:known?) && revision_evidence.known?
                     revision_evidence.value.to_s
                   else
                     "instance:#{selection.instance_id}"
                   end
        Cache.selection_key(
          provider_family:   selection.provider_family,
          model:             selection.model,
          revision:          revision,
          operation:         selection.operation,
          system:            request.system,
          messages:          request.messages,
          tools:             request.tools,
          tool_choice:       request.tool_choice,
          thinking:          request.thinking,
          response_format:   request.response_format,
          max_output_tokens: (request.tokens.is_a?(Hash) ? request.tokens[:max] : nil),
          generation:        request.generation
        )
      end

      def response_cache_shape(kwargs)
        {
          system:          kwargs[:system],
          tools:           kwargs[:tools],
          tool_choice:     kwargs[:tool_choice],
          thinking:        kwargs[:thinking],
          response_format: kwargs[:response_format],
          tokens:          kwargs[:tokens],
          generation:      kwargs[:generation]
        }
      end

      def escalation_enabled?
        routing = Legion::Settings[:llm][:routing]
        return false unless routing.is_a?(Hash)

        esc = routing.is_a?(Hash) ? (routing[:escalation] || {}) : {}
        esc[:enabled] == true
      end

      def escalation_quality_threshold
        routing = Legion::Settings[:llm][:routing]
        return 50 unless routing.is_a?(Hash)

        esc = routing.is_a?(Hash) ? (routing[:escalation] || {}) : {}
        esc[:quality_threshold] || 50
      end

      def emit_non_pipeline_metering(response, model:, provider:, caller: nil, messages: nil)
        return unless response

        usage = response.respond_to?(:usage) ? response.usage : nil
        input    = usage.respond_to?(:input_tokens)    ? usage.input_tokens.to_i    : 0
        output   = usage.respond_to?(:output_tokens)   ? usage.output_tokens.to_i   : 0
        thinking = usage.respond_to?(:thinking_tokens) ? usage.thinking_tokens.to_i : 0

        finish = nil
        if response.respond_to?(:stop_reason)
          finish = response.stop_reason&.to_s
        elsif response.respond_to?(:stop) && response.stop.is_a?(Hash)
          finish = response.stop[:reason]&.to_s
        end

        meta = response.respond_to?(:metadata) ? response.metadata : {}
        meta_hash = meta.is_a?(Hash) ? meta : {}
        latency = (meta_hash[:latency_ms] || meta_hash.dig(:timing, :latency_ms) || 0).to_i
        wall_clock = (meta_hash[:wall_clock_ms] || meta_hash.dig(:timing, :wall_clock_ms) || 0).to_i

        response_content = if response.respond_to?(:text)
                             response.text
                           elsif response.respond_to?(:content)
                             response.content
                           end

        Legion::LLM::Metering.emit(
          provider:          provider,
          model_id:          model,
          request_type:      'chat',
          tier:              'direct',
          input_tokens:      input,
          output_tokens:     output,
          thinking_tokens:   thinking,
          total_tokens:      input + output + thinking,
          finish_reason:     finish,
          provider_instance: response.respond_to?(:instance) ? response.instance : nil,
          latency_ms:        latency,
          wall_clock_ms:     wall_clock,
          caller:            caller,
          event_type:        'llm_completion',
          status:            'success',
          messages:          messages,
          response_content:  response_content
        )
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.inference.non_pipeline_metering')
      end

      def enterprise_privacy?
        if Legion::Settings.respond_to?(:enterprise_privacy?)
          Legion::Settings.enterprise_privacy?
        else
          ENV['LEGION_ENTERPRISE_PRIVACY'] == 'true'
        end
      end

      def emit_privacy_blocked_audit
        Legion::LLM::Audit.emit_prompt(
          request_id: nil, conversation_id: nil, caller: Legion::LLM::PublisherIdentity.caller_hash,
          routing: {}, tokens: {}, status: 'privacy_blocked',
          error: { class: 'PrivacyModeError', message: 'External tiers blocked by enterprise privacy' },
          timestamp: Time.now, request_type: 'chat'
        )
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.inference.emit_privacy_blocked_audit')
      end

      def assert_external_allowed!
        return unless enterprise_privacy?

        emit_privacy_blocked_audit
        raise Legion::LLM::PrivacyModeError,
              'External LLM tiers are disabled: enterprise_data_privacy is enabled. ' \
              'Only local and fleet tiers are permitted.'
      end

      alias assert_cloud_allowed! assert_external_allowed!

      def effective_tier_is_external?(tier, provider)
        return external_tier?(tier.to_sym) if tier
        return false unless enterprise_privacy?

        resolved = provider || Legion::Settings[:llm][:default_provider]
        external_providers = %i[anthropic bedrock openai gemini azure]
        external_providers.include?(resolved&.to_sym)
      end

      alias effective_tier_is_cloud? effective_tier_is_external?

      def external_tier?(tier)
        %i[cloud frontier].include?(tier)
      end
    end
  end
end
