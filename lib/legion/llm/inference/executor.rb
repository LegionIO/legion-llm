# frozen_string_literal: true

require 'concurrent'
require 'faraday'

require_relative '../publisher_identity'
require_relative '../tools/special'
require_relative 'native_tool_loop'
require_relative 'route_attempts'

module Legion
  module LLM
    module Inference
      class Executor # rubocop:disable Metrics/ClassLength
        include Legion::Logging::Helper
        include NativeToolLoop
        include RouteAttempts
        include Steps::Logging
        include Steps::Rbac
        include Steps::Classification
        include Steps::Billing
        include Steps::GaiaAdvisory
        include Steps::PostResponse
        include Steps::RagContext

        attr_reader :request, :profile, :timeline, :tracing, :enrichments,
                    :audit, :warnings, :discovered_tools, :confidence_score,
                    :escalation_chain
        attr_accessor :tool_event_handler

        include Steps::TriggerMatch
        include Steps::SkillInjector
        include Steps::ToolDiscovery
        include Steps::ToolCalls
        include Steps::KnowledgeCapture
        include Steps::ConfidenceScoring
        include Steps::TokenBudget
        include Steps::PromptCache
        include Steps::Debate
        include Steps::Metering
        include Steps::StickyRunners
        include Steps::ToolHistory
        include Steps::StickyPersist

        PRE_PROVIDER_STEPS = %i[
          tracing_init idempotency conversation_uuid context_load
          rbac classification billing gaia_advisory tier_assignment rag_context
          trigger_match sticky_runners skill_injector tool_history_inject tool_discovery
          routing request_normalization token_budget
        ].freeze

        POST_PROVIDER_STEPS = %i[
          response_normalization metering debate confidence_scoring
          tool_calls sticky_persist
          context_store post_response knowledge_capture response_return
        ].freeze

        STEPS = (PRE_PROVIDER_STEPS + %i[provider_call] + POST_PROVIDER_STEPS).freeze

        ASYNC_SAFE_STEPS = %i[post_response knowledge_capture response_return].freeze

        CONFIG_ERROR_PATTERNS = [
          /ValidationException/,
          /AccessDeniedException/,
          /InvalidModel/i,
          /model.*not found/i,
          /not authorized/i,
          /AWS Marketplace/i
        ].freeze

        MAX_NATIVE_TOOL_ROUNDS = 200
        ToolResultEvent = Struct.new(:result, :tool_call_id, :tool_name, :started_at, keyword_init: true)

        ASYNC_THREAD_POOL = Concurrent::FixedThreadPool.new(4, fallback_policy: :caller_runs)

        def initialize(request)
          @request = request
          @profile = Profile.derive(request.caller)
          @timeline = Timeline.new
          @tracing = nil
          @enrichments = {}
          @audit = {}
          @warnings = []
          @timestamps = { received: Time.now }
          @raw_response = nil
          @exchange_id = nil
          @discovered_tools = []
          @triggered_tools = []
          @resolved_provider = nil
          @resolved_instance = nil
          @resolved_model = nil
          @resolved_tier = nil
          @resolved_offering_id = nil
          @resolved_offering_metadata = {}
          @confidence_score = nil
          @escalation_chain = nil
          @escalation_history = []
          @route_attempts = []
          @current_escalation_context = nil
          @proactive_tier_assignment = nil
          @tool_event_handler = nil
          @sticky_turn_snapshot = nil
          @pending_tool_history = Concurrent::Array.new
          @pending_tool_history_mutex = Mutex.new
          @deferred_tool_audits = []
          @injected_tool_map = {}
          @native_tool_source_map = {}
          @freshly_triggered_keys = []
        end

        def call
          log.debug "[llm][executor] action=call request_id=#{@request.id} profile=#{@profile}"
          execute_steps
          build_response
        end

        def call_stream(&block)
          return call unless block

          log.debug "[llm][executor] action=call_stream request_id=#{@request.id} profile=#{@profile}"
          execute_pre_provider_steps
          step_provider_call_stream(&block)
          execute_post_provider_steps
          build_response
        end

        def call_responses(body:, stream: false, &)
          log.debug "[llm][executor] action=call_responses request_id=#{@request.id} profile=#{@profile} stream=#{stream}"
          execute_pre_provider_steps
          execute_provider_request_responses(body: body, stream: stream, &)
          execute_post_provider_steps
          build_response
        end

        private

        def llm_setting(key, default = nil)
          Legion::LLM::Settings.config_value(Legion::LLM::Settings.current_settings, key, default)
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.settings')
          default
        end

        def normalize_offering_metadata(value)
          return {} unless value.is_a?(Hash)

          value.each_with_object({}) do |(key, metadata_value), normalized|
            normalized[key.respond_to?(:to_sym) ? key.to_sym : key] = metadata_value
          end
        end

        def registry_tool_limit
          return nil unless local_provider?

          raw_limit = Legion::LLM::Settings.value(:tool_trigger, :local_tool_limit)
          limit = raw_limit.to_i
          limit.positive? ? limit : nil
        end

        def local_provider?
          %i[ollama vllm].include?(@resolved_provider&.to_sym)
        end

        def inferred_provider_tier(provider)
          return nil unless provider

          meta = Call::Registry.metadata_for(provider, @resolved_instance || :default)
          return meta[:tier].to_sym if meta.is_a?(Hash) && meta[:tier]
          return Router.provider_tier(provider) if defined?(Router) && Router.respond_to?(:provider_tier)

          Router::PROVIDER_TIER.fetch(provider.to_sym, nil) if defined?(Router::PROVIDER_TIER)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.inferred_provider_tier',
                              provider: provider)
          nil
        end

        def execute_steps
          executed = 0
          skipped = 0
          pipeline_start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          step_timings = []
          @step_timing_hash = {}
          STEPS.each do |step|
            if Profile.skip?(@profile, step)
              skipped += 1
              next
            end

            t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            execute_step(step) { send(:"step_#{step}") }
            elapsed_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - t0) * 1000).round
            step_timings << "#{step}=#{elapsed_ms}ms"
            @step_timing_hash[step] = elapsed_ms
            executed += 1
          end
          total_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - pipeline_start) * 1000).round
          @step_timing_hash[:total] = total_ms
          @timestamps[:step_timings] = @step_timing_hash
          log.warn("[pipeline][timing] profile=#{@profile} total=#{total_ms}ms executed=#{executed} skipped=#{skipped} #{step_timings.join(' ')}")
          annotate_top_level_span(steps_executed: executed, steps_skipped: skipped)
        end

        def step_tracing_init
          log.debug "[llm][executor] action=step_tracing_init existing=#{!@request.tracing.nil?}"
          @tracing = Tracing.init(existing: @request.tracing)
          @timeline.record(
            category: :internal, key: 'tracing:init',
            direction: :internal, detail: 'trace initialized',
            from: 'pipeline', to: 'pipeline'
          )
        end

        def step_idempotency; end

        def step_conversation_uuid
          if @request.conversation_id
            log.debug "[llm][executor] action=step_conversation_uuid existing=#{@request.conversation_id}"
            return
          end

          new_id = "conv_#{SecureRandom.hex(8)}"
          log.debug "[llm][executor] action=step_conversation_uuid generated=#{new_id}"
          @request = @request.with(conversation_id: new_id)
        end

        def step_context_load
          conv_id = @request.conversation_id
          unless conv_id
            log.debug '[llm][executor] action=step_context_load skipped=no_conversation_id'
            return
          end

          history = Conversation.messages(conv_id)
          if history.empty?
            log.debug "[llm][executor] action=step_context_load conversation_id=#{conv_id} history=empty"
            return
          end
          log.debug "[llm][executor] action=step_context_load conversation_id=#{conv_id} history_size=#{history.size}"

          curator = Context::Curator.new(conversation_id: conv_id)
          curated = curator.curated_messages

          history = if curated && !curated.empty?
                      @timeline.record(
                        category: :internal, key: 'context:curated',
                        direction: :internal, detail: "curated #{curated.size} of #{history.size} messages",
                        from: 'context_curator', to: 'pipeline'
                      )
                      curated
                    else
                      maybe_compact_history(conv_id, history)
                    end

          archived_history = curator.drop_and_archive(history, conversation_id: conv_id)
          if archived_history.size < history.size
            @timeline.record(
              category: :internal, key: 'context:archived',
              direction: :outbound,
              detail: "archived #{history.size - archived_history.size} prior messages to Apollo",
              from: 'context_curator', to: 'apollo'
            )
            Conversation.replace(conv_id, archived_history)
            history = archived_history
          end

          @enrichments['context:conversation_history'] = history
          @timeline.record(
            category: :internal, key: 'context:loaded',
            direction: :internal, detail: "loaded #{history.size} prior messages",
            from: 'conversation_store', to: 'pipeline'
          )
        end

        def maybe_compact_history(conv_id, history)
          conv_settings = llm_setting(:conversation, {})
          return history unless Legion::LLM::Settings.config_value(conv_settings, :auto_compact)

          threshold = Legion::LLM::Settings.config_value(conv_settings, :summarize_threshold, 50_000)
          target_tokens = Legion::LLM::Settings.config_value(conv_settings, :target_tokens, 20_000)
          preserve_recent = Legion::LLM::Settings.config_value(conv_settings, :preserve_recent, 10)

          estimated = Context::Compressor.estimate_tokens(history)
          return history unless estimated >= threshold

          compact = Context::Compressor.auto_compact(
            history,
            target_tokens:   target_tokens,
            preserve_recent: preserve_recent
          )

          Conversation.replace(conv_id, compact)

          @timeline.record(
            category: :internal, key: 'context:compacted',
            direction: :internal,
            detail: "compacted #{history.size} messages (#{estimated} est. tokens) -> #{compact.size}",
            from: 'compressor', to: 'pipeline'
          )

          compact
        end

        def step_tier_assignment
          gaia_hint = @enrichments['gaia:routing_hint']
          classification = @enrichments['classification:scan']
          assignment = Steps::TierAssigner.assign(
            caller:          @request.caller,
            classification:  classification,
            priority:        @request.priority,
            gaia_hint:       gaia_hint,
            existing_tier:   @request.extra[:tier],
            existing_intent: @request.extra[:intent]
          )
          return unless assignment

          @proactive_tier_assignment = assignment
          @audit[:'routing:tier_assignment'] = {
            outcome:     :success,
            detail:      "proactive tier=#{assignment[:tier]} source=#{assignment[:source]}",
            data:        assignment,
            duration_ms: 0,
            timestamp:   Time.now
          }
          @timeline.record(
            category: :audit, key: 'routing:tier_assignment',
            direction: :internal,
            detail: "tier=#{assignment[:tier]} assigned by #{assignment[:source]}",
            from: 'tier_assigner', to: 'pipeline'
          )
        rescue StandardError => e
          @warnings << "tier assignment error: #{e.message}"
          handle_exception(e, level: :warn, operation: 'llm.pipeline.step_tier_assignment')
        end

        def step_routing
          log.debug "[llm][executor] action=step_routing.enter requested_provider=#{@request.routing[:provider]} requested_model=#{@request.routing[:model]}"
          @timestamps[:routing_start] = Time.now
          state = resolve_routing_state(apply_proactive_tier_assignment(routing_request_state))
          auto_route = state[:auto_route] == true

          @resolved_provider = state[:provider] ||
                               (state[:model] && Router.infer_provider_for_model(state[:model])) ||
                               (llm_setting(:default_provider) unless auto_route)
          @resolved_instance = resolve_provider_instance(state[:instance], @resolved_provider)
          @resolved_model = state[:model] || (llm_setting(:default_model) unless auto_route)
          if auto_route && (@resolved_provider.nil? || @resolved_model.nil?)
            raise ProviderError, 'Auto routing could not resolve an available LLM provider/model'
          end

          @resolved_tier = state[:tier]&.to_sym || inferred_provider_tier(@resolved_provider)
          @resolved_offering_id = state[:offering_id]
          @resolved_offering_metadata = state[:offering_metadata]
          record_forced_tier_selection unless @audit[:'routing:provider_selection']

          log.info '[llm][inference] resolved ' \
                   "provider=#{@resolved_provider} instance=#{@resolved_instance || 'default'} " \
                   "model=#{@resolved_model} offering_id=#{@resolved_offering_id}"
          @timeline.record(
            category: :audit, key: 'routing:provider_selection',
            direction: :internal, detail: "routed to #{@resolved_provider}:#{@resolved_model}",
            from: 'router', to: 'pipeline'
          )
        end

        def resolve_provider_instance(requested_instance, provider)
          return provider_scoped_instance(requested_instance, provider, preserve_unknown: true) if requested_instance

          provider_scoped_instance(llm_setting(:default_instance), provider, preserve_unknown: false)
        end

        def provider_scoped_instance(instance, provider, preserve_unknown:)
          return nil if instance.nil? || instance.to_s.empty? || provider.nil? || provider.to_s.empty?

          provider_sym = provider.to_sym
          instance_sym = instance.to_sym
          return instance_sym if Call::Registry.registered?(provider_sym, instance: instance_sym)
          return nil if Call::Registry.registered?(provider_sym)

          preserve_unknown ? instance_sym : nil
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.provider_scoped_instance')
          preserve_unknown ? instance : nil
        end

        def routing_request_state
          routing_explicit = @request.extra[:routing_explicit]
          request_intent = @request.extra[:intent]
          instance = @request.routing[:instance] || @request.routing[:instance_id] || @request.routing[:provider_instance]
          tier = @request.extra[:tier]
          {
            provider:          @request.routing[:provider],
            instance:          instance,
            model:             @request.routing[:model],
            offering_id:       @request.routing[:offering_id] || @request.routing[:id],
            offering_metadata: normalize_offering_metadata(@request.routing[:offering_metadata] ||
                                                           @request.routing[:offering]),
            intent:            routing_intent_for_request(request_intent),
            intent_explicit:   routing_intent_present?(request_intent),
            tier:              tier,
            auto_route:        @request.extra[:auto_route],
            provider_explicit: routing_field_explicit?(routing_explicit, :provider, @request.routing[:provider]),
            instance_explicit: routing_field_explicit?(routing_explicit, :instance, instance),
            tier_explicit:     routing_field_explicit?(routing_explicit, :tier, tier)
          }
        end

        def routing_intent_present?(intent)
          intent.is_a?(Hash) && intent.any?
        end

        def routing_intent_for_request(intent)
          normalized = if intent.is_a?(Hash)
                         intent.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                       else
                         {}
                       end
          required = normalize_required_capabilities(
            normalized.delete(:required_capabilities) || normalized.delete(:requires)
          )

          if @request.stream == true
            normalized[:capability] = :stream if stream_routable_capability?(normalized[:capability])
            required << :streaming
          end

          required << :tools if native_tools_requested_for_routing?
          normalized[:required_capabilities] = required.uniq if required.any?
          normalized
        end

        def stream_routable_capability?(capability)
          capability.nil? || %i[chat completion stream].include?(capability.to_s.downcase.to_sym)
        end

        def native_tools_requested_for_routing?
          Array(@request.tools).any? ||
            requested_deferred_tool_names.any? ||
            @triggered_tools.any? ||
            Tools::Special.pinned_definitions.any?
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.routing_tools_required')
          false
        end

        def normalize_required_capabilities(capabilities)
          aliases = {
            function_calling: :tools,
            functions:        :tools,
            tool:             :tools,
            tool_use:         :tools,
            stream:           :streaming,
            stream_chat:      :streaming
          }
          Array(capabilities).compact.each_with_object([]) do |capability, normalized|
            next unless capability.respond_to?(:to_s)

            capability_sym = capability.to_s.downcase.strip.to_sym
            next if capability_sym.to_s.empty?

            normalized << capability_sym
            alias_sym = aliases[capability_sym]
            normalized << alias_sym if alias_sym
          end.uniq
        end

        def apply_proactive_tier_assignment(state)
          # Forced assignments carry security/privacy constraints and override
          # caller-supplied tier/intent. Advisory assignments only fill blanks.
          if @proactive_tier_assignment&.dig(:forced)
            state[:tier] = @proactive_tier_assignment[:tier]
            state[:tier_explicit] = true
            state[:intent] = merge_routing_intent(state[:intent], @proactive_tier_assignment[:intent])
            log.info "[llm][routing] action=forced_tier source=#{@proactive_tier_assignment[:source]} tier=#{state[:tier]}"
          elsif @proactive_tier_assignment && !state[:tier] && !state[:intent] && !state[:instance] &&
                !state[:provider] && !state[:model]
            state[:tier] = @proactive_tier_assignment[:tier]
            state[:tier_explicit] = true
            state[:intent] = @proactive_tier_assignment[:intent]
          end
          state
        end

        def resolve_routing_state(state)
          return state unless defined?(Router)

          explicit_route = state[:provider_explicit] || state[:instance_explicit] || state[:tier_explicit]
          auto_route = state[:auto_route] == true
          intent_route = state[:intent_explicit] && state[:intent] && Router.routing_enabled?
          return state unless explicit_route || auto_route || intent_route

          resolution = routing_resolution_for(state)
          return state unless resolution

          apply_routing_resolution(state, resolution)
        end

        def routing_resolution_for(state)
          if state[:auto_route] == true || (state[:intent_explicit] && state[:intent] && pipeline_escalation_enabled?)
            @escalation_chain = Router.resolve_chain(
              intent:                 state[:intent],
              tier:                   state[:tier],
              model:                  state[:model],
              provider:               state[:provider],
              instance:               state[:instance],
              max_escalations:        pipeline_escalation_max_attempts,
              allow_default_fallback: state[:auto_route] != true
            )
            @escalation_chain.primary
          else
            Router.resolve(intent: state[:intent], tier: state[:tier], model: state[:model],
                           provider: state[:provider], instance: state[:instance])
          end
        end

        def apply_routing_resolution(state, resolution)
          provider_changed = resolution.provider && resolution.provider != state[:provider]
          state[:provider] = resolution.provider
          state[:instance] = if resolution.instance
                               resolution.instance
                             elsif provider_changed
                               nil
                             else
                               state[:instance]
                             end
          state[:model] = resolution.model
          state[:tier] = resolution.tier
          state[:offering_id] = resolution.offering_id || state[:offering_id]
          state[:offering_metadata] = resolution.offering_metadata unless resolution.offering_metadata.empty?
          @audit[:'routing:provider_selection'] = {
            outcome: :success,
            detail: "selected #{state[:provider]}:#{state[:model]} via #{resolution.rule}",
            data: { strategy: resolution.rule, tier: resolution.tier, instance: state[:instance],
                    offering_id: state[:offering_id], offering_metadata: state[:offering_metadata] }.compact,
            duration_ms: 0, timestamp: Time.now
          }
          state
        end

        def routing_field_explicit?(flags, key, value)
          return false if value.nil? || value.to_s.empty?
          return true unless flags.is_a?(Hash)

          flags.fetch(key, flags.fetch(key.to_s, true)) == true
        end

        def step_request_normalization
          @exchange_id = Tracing.exchange_id
        end

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
          providers_tried = []
          begin
            execute_provider_request
          rescue Legion::LLM::AuthError, Faraday::UnauthorizedError, Faraday::ForbiddenError => e
            try_fallback_or_raise(e, providers_tried, operation: 'provider_call.auth',
                                                      reason: 'auth_failed', error_class: Legion::LLM::AuthError)
            retry
          rescue Legion::LLM::ContextOverflow => e
            try_fallback_or_raise(e, providers_tried, operation: 'provider_call.context_overflow',
                                                      reason: 'context_overflow', error_class: Legion::LLM::ContextOverflow)
            retry
          rescue Legion::LLM::ProviderError => e
            try_fallback_or_raise(e, providers_tried, operation: 'provider_call.bad_request',
                                                      reason: 'bad_request', error_class: Legion::LLM::ProviderError)
            retry
          rescue Legion::LLM::RateLimitError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.rate_limit',
                              provider: @resolved_provider, model: @resolved_model)
            emit_error_audit(e, status: 'rate_limited')
            raise Legion::LLM::RateLimitError, e.message
          rescue Legion::LLM::ProviderDown, Faraday::ServerError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.provider_error',
                              provider: @resolved_provider, model: @resolved_model)
            emit_error_audit(e, status: 'provider_error')
            raise Legion::LLM::ProviderError, e.message
          rescue Faraday::TooManyRequestsError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.http_rate_limit',
                              provider: @resolved_provider, model: @resolved_model)
            emit_error_audit(e, status: 'rate_limited')
            raise Legion::LLM::RateLimitError.new(e.message, retry_after: extract_retry_after(e))
          rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.provider_down',
                              provider: @resolved_provider, model: @resolved_model)
            emit_error_audit(e, status: 'provider_down')
            raise Legion::LLM::ProviderDown, e.message
          end
        end

        def run_provider_call_with_escalation(stream_block: nil)
          @escalation_chain ||= build_default_escalation_chain
          chain = @escalation_chain
          threshold = pipeline_escalation_quality_threshold
          quality_check = @request.extra[:quality_check]
          succeeded = false
          tried = []
          @last_escalation_error = nil
          log.debug "[llm][executor] action=escalation.enter chain_size=#{chain.size} threshold=#{threshold}"

          primary_tier = @escalation_chain.primary&.tier

          chain.each do |resolution|
            next if tried.any? { |t| t[:provider] == resolution.provider && t[:instance] == resolution.instance && t[:model] == resolution.model }

            succeeded = run_escalation_resolution(resolution, threshold, quality_check, tried, primary_tier,
                                                  stream_block: stream_block)
            break if succeeded
          end
          return if succeeded
          raise @last_escalation_error if chain.size <= 1 && @last_escalation_error

          emit_error_audit(
            EscalationExhausted.new("All #{@escalation_history.size} attempts failed"),
            status: 'escalation_exhausted'
          )
          raise EscalationExhausted, "All #{@escalation_history.size} escalation attempts failed"
        end

        def run_escalation_resolution(resolution, threshold, quality_check, tried, primary_tier, stream_block: nil)
          move_type = if tried.empty?
                        :primary
                      elsif resolution.tier == primary_tier
                        :lateral
                      else
                        :escalation
                      end
          log.info "[llm][escalation] action=attempt move=#{move_type} provider=#{resolution.provider} model=#{resolution.model} tier=#{resolution.tier}"

          start_time = Time.now
          @resolved_provider = resolution.provider
          @resolved_instance = resolution.instance
          @resolved_model = resolution.model
          @resolved_tier = resolution.tier
          @resolved_offering_id = resolution.offering_id
          @resolved_offering_metadata = resolution.offering_metadata
          succeeded = attempt_escalation(resolution, threshold, quality_check, start_time, stream_block: stream_block)
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
          tried << { provider: resolution.provider, instance: resolution.instance, model: resolution.model }
          record_escalation_failure(e, resolution, start_time,
                                    outcome:   :error,
                                    operation: 'llm.pipeline.escalation_attempt')
          false
        end

        def attempt_escalation(resolution, threshold, quality_check, start_time, stream_block: nil)
          @current_escalation_context = {
            attempt:      @escalation_history.size + 1,
            max_attempts: @escalation_chain&.max_attempts
          }.compact
          if stream_block
            execute_provider_request_stream(&stream_block)
            result = Quality::Checker::QualityResult.new(passed: true, failures: [])
          else
            execute_provider_request
            result = Quality::Checker.check(@raw_response, quality_threshold: threshold, quality_check: quality_check)
          end
          duration_ms = ((Time.now - start_time) * 1000).round
          outcome = result.passed ? :success : :quality_failure
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
          result.passed
        ensure
          @current_escalation_context = nil
        end

        def report_escalation_quality_failure(resolution, result)
          Router.health_tracker.report(
            provider:    resolution.provider,
            instance:    resolution.instance,
            offering_id: resolution.offering_id,
            signal:      :quality_failure,
            value:       1,
            metadata:    {
              model:    resolution.model,
              failures: Array(result.failures)
            }
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.escalation_attempt.health_report',
                              provider: resolution.provider, model: resolution.model)
        end

        def record_escalation_failure(err, resolution, start_time, outcome:, operation:, handled: false)
          @last_escalation_error = err
          duration_ms = ((Time.now - start_time) * 1000).round
          handle_exception(err, level: :warn, handled: handled, operation: operation,
                               provider: resolution.provider, model: resolution.model, duration_ms: duration_ms)
          if config_error?(err)
            Router.health_tracker.deny_model(
              provider: resolution.provider,
              model:    resolution.model,
              instance: resolution.instance,
              reason:   err.message
            )
          else
            Router.health_tracker.report(provider: resolution.provider, offering_id: resolution.offering_id,
                                         signal: :error, value: 1,
                                         metadata: { reason: err.class.name, message: err.message })
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
        end

        def build_default_escalation_chain
          primary = Router.explicit_resolution(@resolved_tier, @resolved_provider, @resolved_model, @resolved_instance)
          fallbacks = build_fallback_resolutions(
            exclude_provider: @resolved_provider,
            exclude_instance: @resolved_instance,
            primary_tier:     @resolved_tier
          )
          resolutions = ([primary] + fallbacks).compact.uniq { |r| [r.provider, r.instance, r.model] }
          Router::EscalationChain.new(resolutions: resolutions, max_attempts: pipeline_escalation_max_attempts)
        end

        def build_fallback_resolutions(exclude_provider: nil, exclude_instance: nil, primary_tier: nil)
          tier_rank = Router.tier_rank
          primary_rank = primary_tier ? (tier_rank[primary_tier.to_sym] || 99) : 99

          candidates = Call::Registry.all_instances.filter_map do |entry|
            next if entry[:provider] == exclude_provider&.to_sym && entry[:instance] == (exclude_instance&.to_sym || :default)
            next if entry[:provider] == exclude_provider&.to_sym && exclude_instance.nil?

            model = Router.send(:registry_default_model, entry)
            next unless model

            tier = Router::PROVIDER_TIER.fetch(entry[:provider], :frontier)
            Router::Resolution.new(
              tier:     tier,
              provider: entry[:provider],
              instance: entry[:instance] == :default ? nil : entry[:instance],
              model:    model,
              rule:     'escalation_fallback'
            )
          end

          # Lateral alternatives (same tier) come first; escalations (higher tier) follow;
          # lower-ranked tiers are appended last.
          candidates.sort_by do |r|
            r_rank = tier_rank[r.tier] || 99
            rank_diff = r_rank - primary_rank
            bucket = if rank_diff.zero?
                       0
                     elsif rank_diff.positive?
                       1
                     else
                       2
                     end
            [bucket, r_rank]
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

        def escalation_attempt_hash(resolution, outcome:, failures:, duration_ms:)
          attempt = { model: resolution.model, provider: resolution.provider, tier: resolution.tier,
                      outcome: outcome, failures: failures, duration_ms: duration_ms }
          attempt[:offering_id] = resolution.offering_id if resolution.offering_id
          attempt[:offering_metadata] = resolution.offering_metadata unless resolution.offering_metadata.empty?
          attempt
        end

        def merge_routing_intent(existing, assignment)
          existing_hash = existing.is_a?(Hash) ? existing : {}
          assignment_hash = assignment.is_a?(Hash) ? assignment : {}
          existing_hash.merge(assignment_hash)
        end

        def record_forced_tier_selection
          return unless @proactive_tier_assignment&.dig(:forced)

          @audit[:'routing:provider_selection'] = {
            outcome:     :success,
            detail:      "forced tier #{@resolved_tier} by #{@proactive_tier_assignment[:source]}",
            data:        { tier: @resolved_tier, strategy: @proactive_tier_assignment[:source],
                           provider: @resolved_provider, model: @resolved_model }.compact,
            duration_ms: 0,
            timestamp:   Time.now
          }
        end

        def pipeline_escalation_enabled?
          routing = llm_setting(:routing)
          return false unless routing.is_a?(Hash)

          esc = Legion::LLM::Settings.config_value(routing, :escalation, {})
          Legion::LLM::Settings.config_value(esc, :enabled) == true && Legion::LLM::Settings.config_value(esc, :pipeline_enabled) == true
        end

        def pipeline_escalation_max_attempts
          routing = llm_setting(:routing)
          return 3 unless routing.is_a?(Hash)

          esc = Legion::LLM::Settings.config_value(routing, :escalation, {})
          Legion::LLM::Settings.config_value(esc, :max_attempts, 3)
        end

        def pipeline_escalation_quality_threshold
          routing = llm_setting(:routing)
          return 50 unless routing.is_a?(Hash)

          esc = Legion::LLM::Settings.config_value(routing, :escalation, {})
          Legion::LLM::Settings.config_value(esc, :quality_threshold, 50)
        end

        def execute_provider_request
          @timestamps[:provider_start] = Time.now
          @timeline.record(
            category: :provider, key: 'provider:request_sent',
            exchange_id: @exchange_id, direction: :outbound,
            detail: "calling #{@resolved_provider}",
            from: 'pipeline', to: "provider:#{@resolved_provider}"
          )

          unless fleet_dispatch? || use_native_dispatch?(@resolved_provider)
            raise Legion::LLM::ProviderError, "Native provider not registered: #{@resolved_provider}"
          end

          execute_provider_request_native

          @timestamps[:provider_end] = Time.now
          record_provider_response
        end

        def execute_provider_request_native
          result = execute_native_tool_loop
          merge_response_offering_metadata(result[:metadata])
          @raw_response = Call::NativeResponseAdapter.new(result)
        end

        def native_dispatch_messages
          apply_conversation_breakpoint(@request.messages)
        end

        def native_dispatch_options
          injected_system = if @native_tool_loop_round.to_i.positive?
                              @cached_injected_system
                            else
                              @cached_injected_system = EnrichmentInjector.inject(
                                system:      @request.system,
                                enrichments: @enrichments
                              )
                            end

          options = {
            system:            injected_system,
            offering_id:       @resolved_offering_id,
            offering_metadata: @resolved_offering_metadata
          }
          options[:tools] = native_dispatch_tools if native_dispatch_tools.any?
          options[:tool_prefs] = native_tool_prefs if native_dispatch_tools.any? && native_tool_prefs
          options[:thinking] = native_dispatch_thinking if native_dispatch_thinking
          options.compact
        end

        def native_dispatch_chat_options
          opts = { model: @resolved_model, provider: @resolved_provider }
          opts[:instance] = @resolved_instance if @resolved_instance
          opts[:thinking] = native_dispatch_thinking if native_dispatch_thinking
          opts.compact
        end

        def native_dispatch_thinking
          return @request.thinking if @request.thinking
          return { enabled: false } if @resolved_provider.to_s == 'vllm' && native_dispatch_tools.any?

          nil
        end

        def native_dispatch_tools
          @native_dispatch_tools ||= native_tool_definitions.to_h { |tool| [tool.name.to_sym, tool.to_h] }
        end

        def native_tool_definitions
          @native_tool_definitions ||= begin
            definitions = []
            add_pinned_special_tool_definitions(definitions)
            Array(@request.tools).each { |tool| add_native_tool_definition(definitions, tool) }
            add_registry_tool_definitions(definitions) if registry_tool_injection_requested?
            log.debug "[llm][executor] action=native_tool_definitions.built count=#{definitions.size}"
            log_native_tool_definitions(definitions)
            definitions
          end
        end

        def registry_tool_injection_requested?
          !(@request.respond_to?(:suppress_tools) && @request.suppress_tools)
        end

        def client_tool_passthrough_enabled?
          if @request.respond_to?(:metadata)
            metadata = @request.metadata || {}
            value = metadata.key?(:client_tool_passthrough) ? metadata[:client_tool_passthrough] : metadata['client_tool_passthrough']
            return value if [true, false].include?(value)
          end

          Legion::LLM::Settings.value(:tool_trigger, :client_tool_passthrough) != false
        end

        def non_executable_client_tool?(definition)
          source = definition.respond_to?(:source) ? definition.source : {}
          return false unless source.is_a?(Hash)

          source_type = source[:type] || source['type']
          executable = source.key?(:executable) ? source[:executable] : source['executable']
          source_type.respond_to?(:to_sym) && source_type.to_sym == :client && executable != true
        end

        def add_pinned_special_tool_definitions(definitions)
          Tools::Special.pinned_definitions.each do |definition|
            next if definitions.any? { |existing| existing.name == definition.name }

            @native_tool_source_map[definition.name] = definition.source
            definitions << definition
          end
        end

        def add_native_tool_definition(definitions, tool)
          definition = case tool
                       when Types::ToolDefinition
                         tool
                       when Hash
                         Types::ToolDefinition.from_hash(tool, source: tool[:source] || tool['source'] || { type: :client, executable: false })
                       else
                         Types::ToolDefinition.from_tool_class(tool)
                       end
          if non_executable_client_tool?(definition) && !client_tool_passthrough_enabled?
            log.info(
              "[llm][tools][inject] action=client_tool_skipped request_id=#{request_log_value(:id, 'unknown')} " \
              "conversation_id=#{request_log_value(:conversation_id, 'none') || 'none'} name=#{definition.name} " \
              'reason=client_passthrough_not_enabled'
            )
            return
          end
          return if gaia_tool_suppressed?(definition.name)
          return if definitions.any? { |existing| existing.name == definition.name }

          @injected_tool_map[definition.name] = definition.source[:tool_class] if definition.source[:tool_class]
          @native_tool_source_map[definition.name] = definition.source
          definitions << definition
        rescue StandardError => e
          @warnings << "Failed to define tool: #{e.message}"
          handle_exception(e, level: :warn, operation: 'llm.pipeline.native_tool_definition')
        end

        def add_registry_tool_definitions(definitions)
          return unless registry_tool_sources_available?

          count_before = definitions.size
          add_settings_extensions_tool_definitions(definitions)
          count_after = definitions.size
          log.info(
            "[llm][tools] registry_injection count_before=#{count_before} count_after=#{count_after} " \
            "added=#{count_after - count_before} limit=#{registry_tool_limit}"
          )
        rescue StandardError => e
          @warnings << "Tool definition error: #{e.message}"
          handle_exception(e, level: :error, operation: 'llm.pipeline.native_registry_tools')
        end

        def add_settings_extensions_tool_definitions(definitions)
          existing_names = definitions.map(&:name)
          inject_limit = registry_tool_limit
          registry_added = 0

          always_entries = Legion::Settings::Extensions.filter_tools(deferred: false)
          gaia_entries = gaia_advisory_tool_entries
          triggered_entries = @triggered_tools.any? ? Array(@triggered_tools) : []
          prioritized = if local_provider?
                          gaia_entries + triggered_entries + always_entries
                        else
                          always_entries + gaia_entries + triggered_entries
                        end

          prioritized.each do |entry|
            break if inject_limit && registry_added >= inject_limit

            definition = if entry.is_a?(Hash) && entry[:name]
                           Types::ToolDefinition.from_registry_entry(entry)
                         else
                           Types::ToolDefinition.from_tool_class(entry)
                         end
            next if gaia_tool_suppressed?(definition.name)
            next if existing_names.include?(definition.name)

            tool_class = entry.is_a?(Hash) ? entry[:tool_class] : entry
            @injected_tool_map[definition.name] = tool_class if tool_class
            @native_tool_source_map[definition.name] = definition.source
            definitions << definition
            existing_names << definition.name
            registry_added += 1
          end

          add_requested_deferred_tool_definitions_from_settings(definitions, existing_names)
        end

        def add_requested_deferred_tool_definitions_from_settings(definitions, injected_names)
          requested = requested_deferred_tool_names
          return if requested.empty?

          deferred_entries = Legion::Settings::Extensions.filter_tools(deferred: true)
          deferred_entries.each do |entry|
            definition = Types::ToolDefinition.from_registry_entry(entry)
            next unless requested.include?(definition.name)
            next if gaia_tool_suppressed?(definition.name)
            next if injected_names.include?(definition.name)

            @injected_tool_map[definition.name] = entry[:tool_class] if entry[:tool_class]
            @native_tool_source_map[definition.name] = definition.source
            definitions << definition
            injected_names << definition.name
          end
        end

        def native_assistant_tool_message(result, tool_calls)
          { role: :assistant, content: result[:result].to_s, tool_calls: tool_calls }
        end

        def native_tool_result_message(tool_call, dispatch_result)
          {
            role:         :tool,
            content:      native_tool_result_content(dispatch_result),
            tool_call_id: tool_call[:id],
            name:         tool_call[:name]
          }.compact
        end

        def dispatch_native_tool_call(tool_call, round)
          normalized_call = normalize_native_tool_call(tool_call)
          source = find_tool_source(normalized_call[:name])
          log.debug "[llm][executor] action=dispatch_native_tool_call round=#{round} tool=#{normalized_call[:name]} source_type=#{source[:type]}"
          emit_tool_call_event(normalized_call, round)
          result = ToolDispatcher.dispatch(
            tool_call:   normalized_call,
            source:      source,
            exchange_id: Tracing.exchange_id
          )
          emit_tool_result_event(
            ToolResultEvent.new(
              result:       native_tool_result_content(result),
              tool_call_id: normalized_call[:id],
              tool_name:    normalized_call[:name],
              started_at:   Thread.current[:legion_current_tool_started_at]
            )
          )
          result
        ensure
          Thread.current[:legion_current_tool_call_id] = nil
          Thread.current[:legion_current_tool_name] = nil
          Thread.current[:legion_current_tool_started_at] = nil
          Thread.current[:legion_current_tool_history_index] = nil
        end

        def normalize_native_tool_call(tool_call)
          normalized = if tool_call.respond_to?(:transform_keys)
                         tool_call.transform_keys(&:to_sym)
                       elsif tool_call.respond_to?(:name)
                         {
                           id:        tool_call.respond_to?(:id) ? tool_call.id : nil,
                           name:      tool_call.name,
                           arguments: tool_call.respond_to?(:arguments) ? tool_call.arguments : {}
                         }
                       else
                         {}
                       end
          normalized[:arguments] = normalize_tool_arguments(normalized[:arguments])
          normalized[:id] ||= "call_#{SecureRandom.hex(12)}"
          normalized
        end

        def native_tool_result_content(result)
          raw = result[:result] || result[:content] || result['result'] || result['content']
          raw.is_a?(String) ? raw : Legion::JSON.dump(raw || {})
        end

        def use_native_dispatch?(provider)
          return false unless defined?(Call::Dispatch)
          return false unless provider

          layer_settings = llm_setting(:provider_layer, {})
          mode = Legion::LLM::Settings.config_value(layer_settings, :mode, 'auto').to_s

          %w[native auto].include?(mode)
        end

        def merge_response_offering_metadata(metadata)
          return unless metadata.is_a?(Hash)

          offering = normalize_offering_metadata(metadata[:offering] || metadata['offering'] || metadata)
          return if offering.empty?

          @resolved_offering_metadata = @resolved_offering_metadata.merge(offering)
          @resolved_offering_id = @resolved_offering_metadata[:offering_id] if @resolved_offering_id.nil?
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

        def report_provider_health(signal, duration_ms, metadata: {})
          return unless defined?(Router) && Router.routing_enabled?

          Router.health_tracker.report(provider: @resolved_provider, offering_id: @resolved_offering_id,
                                       signal: signal, value: 1, metadata: metadata.merge(duration_ms: duration_ms))
          Router.health_tracker.report(provider: @resolved_provider, offering_id: @resolved_offering_id,
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
            request_type:    'chat'
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.emit_error_audit')
        end

        def config_error?(err)
          name = err.class.name.to_s
          msg = err.message.to_s
          CONFIG_ERROR_PATTERNS.any? { |pat| pat.match?(name) || pat.match?(msg) }
        end

        def execute_pre_provider_steps
          log.debug "[llm][executor] action=pre_provider_steps.enter step_count=#{PRE_PROVIDER_STEPS.size}"
          PRE_PROVIDER_STEPS.each do |step|
            next if Profile.skip?(@profile, step)

            execute_step(step) { send(:"step_#{step}") }
          end
          log.debug '[llm][executor] action=pre_provider_steps.complete'
        end

        def execute_post_provider_steps
          async = async_post_enabled?
          log.debug "[llm][executor] action=post_provider_steps.enter async=#{async} step_count=#{POST_PROVIDER_STEPS.size}"
          if async
            execute_post_provider_steps_mixed
          else
            POST_PROVIDER_STEPS.each do |step|
              next if Profile.skip?(@profile, step)

              execute_step(step) { send(:"step_#{step}") }
            end
          end
          log.debug '[llm][executor] action=post_provider_steps.complete'
        end

        def execute_post_provider_steps_mixed
          POST_PROVIDER_STEPS.each do |step|
            next if Profile.skip?(@profile, step)
            next if ASYNC_SAFE_STEPS.include?(step)

            execute_step(step) { send(:"step_#{step}") }
          end

          async_steps = POST_PROVIDER_STEPS.select { |s| ASYNC_SAFE_STEPS.include?(s) }
          return if async_steps.empty?

          # Snapshot timeline and warnings before firing the async thread so that
          # build_response (called on the main thread immediately after) reads a
          # consistent, immutable view rather than racing with async writes.
          @_response_timeline_snapshot = @timeline.events.dup.freeze
          @_response_warnings_snapshot = @warnings.dup.freeze
          @_response_participants_snapshot = @timeline.participants.dup.freeze

          profile = @profile
          ASYNC_THREAD_POOL.post do
            async_steps.each do |step|
              next if Profile.skip?(profile, step)

              send(:"step_#{step}")
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.async_post_steps', steps: async_steps)
          end
        end

        private :execute_post_provider_steps_mixed

        def async_post_enabled?
          llm_setting(:pipeline_async_post_steps) == true
        end

        private :async_post_enabled?

        def step_provider_call_stream(&block)
          if pipeline_escalation_enabled?
            run_provider_call_with_escalation(stream_block: block)
            return
          end

          providers_tried = []
          begin
            execute_provider_request_stream(&block)
          rescue Legion::LLM::AuthError, Faraday::UnauthorizedError, Faraday::ForbiddenError => e
            try_fallback_or_raise(e, providers_tried, operation: 'provider_call_stream.auth',
                                                      reason: 'auth_failed', error_class: Legion::LLM::AuthError)
            retry
          rescue Legion::LLM::ContextOverflow => e
            try_fallback_or_raise(e, providers_tried, operation: 'provider_call_stream.context_overflow',
                                                      reason: 'context_overflow', error_class: Legion::LLM::ContextOverflow)
            retry
          rescue Legion::LLM::ProviderError => e
            try_fallback_or_raise(e, providers_tried, operation: 'provider_call_stream.bad_request',
                                                      reason: 'bad_request', error_class: Legion::LLM::ProviderError)
            retry
          rescue Legion::LLM::RateLimitError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.rate_limit',
                              provider: @resolved_provider, model: @resolved_model)
            emit_error_audit(e, status: 'rate_limited')
            raise Legion::LLM::RateLimitError, e.message
          rescue Legion::LLM::ProviderDown, Faraday::ServerError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.provider_error',
                              provider: @resolved_provider, model: @resolved_model)
            emit_error_audit(e, status: 'provider_error')
            raise Legion::LLM::ProviderError, e.message
          rescue Faraday::TooManyRequestsError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.http_rate_limit',
                              provider: @resolved_provider, model: @resolved_model)
            emit_error_audit(e, status: 'rate_limited')
            raise Legion::LLM::RateLimitError.new(e.message, retry_after: extract_retry_after(e))
          rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.provider_down',
                              provider: @resolved_provider, model: @resolved_model)
            emit_error_audit(e, status: 'provider_down')
            raise Legion::LLM::ProviderDown, e.message
          end
        end

        def execute_provider_request_stream(&)
          @timestamps[:provider_start] = Time.now
          @timeline.record(
            category: :provider, key: 'provider:request_sent',
            exchange_id: @exchange_id, direction: :outbound,
            detail: "streaming from #{@resolved_provider}",
            from: 'pipeline', to: "provider:#{@resolved_provider}"
          )

          unless fleet_dispatch? || use_native_dispatch?(@resolved_provider)
            raise Legion::LLM::ProviderError, "Native provider not registered: #{@resolved_provider}"
          end

          execute_provider_request_stream_native(&)

          @timestamps[:provider_end] = Time.now
          record_provider_response
        end

        def execute_provider_request_stream_native(&)
          result = execute_native_streaming_tool_loop(&)
          merge_response_offering_metadata(result[:metadata])
          @raw_response = Call::NativeResponseAdapter.new(result)
        end

        def execute_provider_request_responses(body:, stream:, &block)
          @timestamps[:provider_start] = Time.now
          @timeline.record(
            category: :provider, key: 'provider:request_sent',
            exchange_id: @exchange_id, direction: :outbound,
            detail: "responses from #{@resolved_provider}",
            from: 'pipeline', to: "provider:#{@resolved_provider}"
          )

          raise Legion::LLM::ProviderError, "Native provider not registered: #{@resolved_provider}" unless use_native_dispatch?(@resolved_provider)

          result = dispatch_responses_request(
            body:         body,
            messages:     native_dispatch_messages,
            stream:       stream,
            stream_block: block
          )
          merge_response_offering_metadata(result[:metadata])
          @raw_response = Call::NativeResponseAdapter.new(result)

          @timestamps[:provider_end] = Time.now
          record_provider_response
        end

        def normalize_message_content(content)
          return content if content.nil? || content.is_a?(String)
          return content unless content.is_a?(Array)

          text_parts = content.filter_map do |b|
            next unless (b[:type] || b['type']).to_s == 'text'

            b[:text] || b['text']
          end
          text_parts.empty? ? nil : text_parts.join("\n\n")
        end

        def emit_tool_call_event(tool_call, round)
          tc_id   = tool_call_field(tool_call, :id)
          tc_name = tool_call_field(tool_call, :name)
          tc_args = tool_call_field(tool_call, :arguments)
          started_at = Time.now

          typed_call = Types::ToolCall.build(
            id: tc_id, name: tc_name, arguments: tc_args,
            exchange_id: @exchange_id, started_at: started_at
          )

          log.debug("[pipeline][tool-call] action=emit round=#{round} id=#{tc_id} tool=#{tc_name}")
          log.info("[pipeline][tool-call] round=#{round} id=#{tc_id} tool=#{tc_name}")

          @pending_tool_history_mutex.synchronize do
            pending_index = @pending_tool_history.size
            @pending_tool_history << {
              tool_call_id:  tc_id,
              pending_index: pending_index,
              tool_name:     tc_name,
              args:          tc_args,
              result:        nil,
              error:         false,
              runner_key:    nil,
              typed_call:    typed_call
            }
            Thread.current[:legion_current_tool_history_index] = pending_index
          end

          Thread.current[:legion_current_tool_call_id] = tc_id
          Thread.current[:legion_current_tool_name] = tc_name
          Thread.current[:legion_current_tool_started_at] = started_at

          @tool_event_handler&.call(
            type: :tool_call, tool_call_id: tc_id, tool_name: tc_name,
            arguments: tc_args, round: round, started_at: started_at
          )
        end

        def emit_tool_result_event(tool_result)
          tc_id      = tool_result.respond_to?(:tool_call_id) ? tool_result.tool_call_id : Thread.current[:legion_current_tool_call_id]
          tc_name    = tool_result.respond_to?(:tool_name)    ? tool_result.tool_name    : Thread.current[:legion_current_tool_name]
          started_at = tool_result.respond_to?(:started_at)   ? tool_result.started_at   : Thread.current[:legion_current_tool_started_at]
          finished_at = Time.now
          raw = tool_result.respond_to?(:result) ? tool_result.result : tool_result
          duration_ms = started_at ? ((finished_at - started_at) * 1000).round : nil

          result_str = (raw.is_a?(String) ? raw : raw.to_s)
          result_str = result_str.encode('UTF-8', invalid: :replace, undef: :replace, replace: '�') unless result_str.valid_encoding?
          result_str = result_str.delete("\x00")
          is_error = raw.is_a?(Hash) && (raw[:error] || raw['error']) ? true : false

          @pending_tool_history_mutex.synchronize do
            entry = @pending_tool_history.find { |e| e[:tool_call_id] == tc_id && e[:result].nil? }
            entry ||= @pending_tool_history[Thread.current[:legion_current_tool_history_index]]
            if entry
              entry[:result] = result_str.is_a?(String) ? result_str : result_str.to_s
              entry[:error]  = is_error
              if entry[:typed_call]
                entry[:typed_call] = entry[:typed_call].with_result(
                  result:      result_str[0, 4096],
                  status:      is_error ? :error : :success,
                  duration_ms: duration_ms,
                  finished_at: finished_at
                )
              end
            end
          end

          log.debug("[pipeline][tool-result] action=emit id=#{tc_id} tool=#{tc_name} status=#{is_error ? :error : :success} duration_ms=#{duration_ms}")
          log.info("[pipeline][tool-result] id=#{tc_id} tool=#{tc_name} duration_ms=#{duration_ms}")

          @tool_event_handler&.call(
            type: :tool_result, tool_call_id: tc_id, tool_name: tc_name,
            result: result_str[0, 4096], result_size: result_str.bytesize,
            started_at: started_at, finished_at: finished_at, duration_ms: duration_ms
          )

          publish_tool_audit(tc_id, tc_name, result_str, is_error, duration_ms, started_at, finished_at)
        end

        def publish_tool_audit(tc_id, tc_name, result_str, is_error, duration_ms, started_at, finished_at)
          @deferred_tool_audits << {
            tc_id: tc_id, tc_name: tc_name, result_str: result_str,
            is_error: is_error, duration_ms: duration_ms,
            started_at: started_at, finished_at: finished_at
          }
        end

        def flush_deferred_tool_audits
          return if @deferred_tool_audits.empty?

          audits = @deferred_tool_audits.dup
          @deferred_tool_audits.clear

          request_id      = @request.id
          conversation_id = @request.conversation_id
          exchange_id     = @exchange_id
          caller_data     = @request.caller
          classification  = @request.classification
          tracing         = @tracing

          Concurrent::Promises.future do
            audits.each do |audit|
              Legion::LLM::Audit.emit_tools(
                request_id:      request_id,
                conversation_id: conversation_id,
                exchange_id:     exchange_id,
                tool_name:       audit[:tc_name],
                tool_call:       {
                  id:          audit[:tc_id],
                  name:        audit[:tc_name],
                  status:      audit[:is_error] ? :error : :success,
                  duration_ms: audit[:duration_ms],
                  started_at:  audit[:started_at],
                  finished_at: audit[:finished_at]
                },
                result:          audit[:result_str][0, 4096],
                caller:          caller_data,
                classification:  classification,
                tracing:         tracing,
                timestamp:       audit[:finished_at],
                request_type:    'tool'
              )
            rescue StandardError => e
              Legion::Logging.log.warn("[llm][pipeline] publish_tool_audit failed tool=#{audit[:tc_name]}: #{e.message}")
            end
          end
        end

        def tool_call_field(tool_call, field)
          return tool_call.public_send(field) if tool_call.respond_to?(field)

          tool_call[field]
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.tool_call_field', field: field)
          nil
        end

        def execute_step(name, &block)
          started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          log_step_debug(name, :enter)
          unless pipeline_spans_enabled?
            begin
              result = block.call
              log_step_debug(name, :complete, duration_ms: elapsed_monotonic_ms(started_at))
              return result
            rescue StandardError => e
              log_step_info(name, :failed, error_class: e.class.name)
              raise
            end
          end

          block_called = false
          begin
            result = Legion::Telemetry.with_span("pipeline.#{name}", kind: :internal) do |span|
              block_called = true
              step_result = block.call
              annotate_span(span, name)
              step_result
            end
            log_step_debug(name, :complete, duration_ms: elapsed_monotonic_ms(started_at))
            result
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.with_step_span', step: name, block_called: block_called)
            log_step_info(name, :failed, error_class: e.class.name)
            raise if block_called

            fallback_result = block.call
            log_step_debug(name, :complete_after_span_failure, duration_ms: elapsed_monotonic_ms(started_at))
            fallback_result
          end
        end

        def elapsed_monotonic_ms(started_at)
          ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at) * 1000).round
        end

        def telemetry_enabled?
          !!(defined?(Legion::Telemetry) &&
            Legion::Telemetry.respond_to?(:enabled?) &&
            Legion::Telemetry.enabled?)
        end

        def pipeline_spans_enabled?
          return false unless telemetry_enabled?

          settings = llm_setting(:telemetry)
          return true unless settings.is_a?(Hash)

          Legion::LLM::Settings.config_value(settings, :pipeline_spans, true)
        end

        def annotate_span(span, step_name)
          return unless span.respond_to?(:set_attribute)

          attrs = Steps::SpanAnnotator.attributes_for(step_name, audit: @audit, enrichments: @enrichments)
          attrs.each { |key, val| span.set_attribute(key, val) unless val.nil? }
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.annotate_span', step: step_name)
          nil
        end

        def annotate_top_level_span(steps_executed:, steps_skipped:)
          return unless telemetry_enabled?
          return unless Legion::Telemetry.respond_to?(:current_span)

          span = Legion::Telemetry.current_span
          return unless span.respond_to?(:set_attribute)

          span.set_attribute('legion.pipeline.steps_executed', steps_executed)
          span.set_attribute('legion.pipeline.steps_skipped', steps_skipped)

          cost_entry = @audit[:'billing:budget_check'] || @audit[:'provider:response']
          if cost_entry.is_a?(Hash) && (cost = cost_entry.dig(:data, :estimated_cost_usd) || cost_entry[:estimated_cost_usd])
            span.set_attribute('gen_ai.usage.cost_usd', cost)
          end

          routing_entry = @audit[:'routing:provider_selection']
          if routing_entry.is_a?(Hash) && (data = routing_entry[:data])
            span.set_attribute('routing.strategy', data[:strategy].to_s) if data[:strategy]
            span.set_attribute('routing.tier', data[:tier].to_s) if data[:tier]
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.annotate_top_level_span')
          nil
        end

        def try_fallback_or_raise(error, providers_tried, operation:, reason:, error_class:)
          providers_tried << @resolved_provider
          fallback = find_fallback_provider(exclude: providers_tried)
          handle_exception(
            error,
            level: :warn, operation: "llm.pipeline.#{operation}",
            provider: @resolved_provider, model: @resolved_model,
            fallback_provider: fallback&.dig(:provider)
          )
          raise error_class, "#{@resolved_provider}:#{@resolved_model} #{reason} — #{error.message}" unless fallback

          log.warn "[pipeline] #{@resolved_provider}:#{@resolved_model} #{reason} (#{error.message}), " \
                   "falling back to #{fallback[:provider]}:#{fallback[:model]}"
          from_provider = @resolved_provider
          from_model = @resolved_model
          @resolved_provider = fallback[:provider]
          @resolved_model = fallback[:model]
          @warnings << { type: :provider_fallback, original_error: error.message,
                         fallback: "#{@resolved_provider}:#{@resolved_model}" }
          @tool_event_handler&.call(
            type: :model_fallback,
            from_provider: from_provider, to_provider: @resolved_provider,
            from_model: from_model, to_model: @resolved_model,
            error: error.message, reason: reason
          )
        end

        def find_fallback_provider(exclude: [])
          providers = llm_setting(:providers, {})
          providers.each do |name, config|
            normalized_name = name.to_sym
            next unless config.is_a?(Hash) && Legion::LLM::Settings.config_value(config, :enabled)
            next if exclude.include?(name) || exclude.include?(name.to_s)
            next if exclude.include?(normalized_name)
            next if %i[ollama vllm].include?(normalized_name)

            default_model = Legion::LLM::Settings.config_value(config, :default_model)
            next unless default_model

            return { provider: normalized_name, model: default_model }
          end
          nil
        end

        def step_response_normalization
          # Normalize enrichment keys to consistent string "source:type" format
          normalized = {}
          @enrichments.each do |key, value|
            normalized[key.to_s] = value
          end
          @enrichments = normalized
        end

        def step_metering
          @extracted_tokens ||= extract_tokens
          input_tokens  = @extracted_tokens.respond_to?(:input_tokens)  ? @extracted_tokens.input_tokens.to_i  : 0
          output_tokens = @extracted_tokens.respond_to?(:output_tokens) ? @extracted_tokens.output_tokens.to_i : 0
          tier = @audit.dig(:'routing:provider_selection', :data, :tier)
          latency_ms = if @timestamps[:provider_start] && @timestamps[:provider_end]
                         ((@timestamps[:provider_end] - @timestamps[:provider_start]) * 1000).round
                       else
                         0
                       end
          wall_clock_ms = if @timestamps[:received]
                            ((Time.now - @timestamps[:received]) * 1000).round
                          else
                            0
                          end
          agent = request_agent_context
          cost_usd = estimate_cost(input_tokens, output_tokens)
          log.debug("[pipeline][metering] action=build provider=#{@resolved_provider} model=#{@resolved_model} input=#{input_tokens} output=#{output_tokens}")
          event = Steps::Metering.build_event(
            provider:          @resolved_provider,
            model_id:          @resolved_model,
            offering_id:       @resolved_offering_id,
            offering_metadata: @resolved_offering_metadata,
            tier:              tier,
            request_type:      'chat',
            input_tokens:      input_tokens,
            output_tokens:     output_tokens,
            latency_ms:        latency_ms,
            wall_clock_ms:     wall_clock_ms,
            cost_usd:          cost_usd,
            request_id:        @request.id,
            conversation_id:   @request.conversation_id,
            correlation_id:    @tracing&.dig(:correlation_id),
            caller:            @request.caller,
            identity:          metering_identity,
            billing:           @request.billing,
            agent_id:          agent[:id],
            task_id:           agent[:task_id],
            routing_reason:    @audit.dig(:'routing:provider_selection', :data, :reason)
          )
          Steps::Metering.publish_or_spool(event)
          flush_deferred_tool_audits
        rescue StandardError => e
          @warnings << "metering error: #{e.message}"
          handle_exception(e, level: :warn, operation: 'llm.pipeline.step_metering')
        end

        def estimate_cost(input_tokens, output_tokens)
          model_id = metering_model_id
          if (input_tokens + output_tokens).zero? && model_id
            log.warn(
              "[llm][metering] zero_tokens request_id=#{@request.id} " \
              "provider=#{@resolved_provider || 'none'} model=#{model_id} cost_estimate_skipped=true"
            )
            return nil
          end

          estimated = Legion::LLM::Metering::Pricing.estimate(
            model_id: model_id, input_tokens: input_tokens, output_tokens: output_tokens
          )
          if estimated.nil? && model_id
            log.warn(
              "[llm][metering] cost_estimate_unavailable request_id=#{@request.id} " \
              "provider=#{@resolved_provider || 'none'} model=#{model_id}"
            )
          end
          estimated
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.pipeline.estimate_cost')
          nil
        end

        def metering_model_id
          metadata = @resolved_offering_metadata
          return @resolved_model unless metadata.is_a?(Hash)

          metadata[:canonical_model_alias] || metadata['canonical_model_alias'] || @resolved_model
        end

        def request_agent_context
          direct_agent = normalize_agent_context(@request.agent)
          return direct_agent unless direct_agent.empty?

          caller = @request.caller
          return {} unless caller.is_a?(Hash)

          normalize_agent_context(caller[:agent] || caller['agent'])
        end

        def normalize_agent_context(value)
          return {} unless value.is_a?(Hash)

          value.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
        end

        def metering_identity
          Legion::LLM::PublisherIdentity.current
        end

        def step_context_store
          conv_id = @request.conversation_id
          return unless conv_id

          log.debug("[pipeline][context_store] action=store conversation_id=#{conv_id} message_count=#{@request.messages.size}")

          @request.messages.each do |msg|
            typed_msg = Types::Message.build(
              role:            msg[:role]&.to_sym || :user,
              content:         msg[:content],
              conversation_id: conv_id,
              task_id:         @request.respond_to?(:task_id) ? @request.task_id : nil
            )
            Conversation.append(conv_id,
                                role:    typed_msg.role,
                                content: typed_msg.content)
          end

          assistant_response = nil
          if @raw_response.respond_to?(:content) && @raw_response.content
            tokens = @extracted_tokens || extract_tokens
            typed_assistant = Types::Message.build(
              role:            :assistant,
              content:         @raw_response.content,
              provider:        @resolved_provider,
              model:           @resolved_model,
              input_tokens:    tokens.respond_to?(:input_tokens) ? tokens.input_tokens : nil,
              output_tokens:   tokens.respond_to?(:output_tokens) ? tokens.output_tokens : nil,
              conversation_id: conv_id,
              task_id:         @request.respond_to?(:task_id) ? @request.task_id : nil
            )
            Conversation.append(conv_id,
                                role:          typed_assistant.role,
                                content:       typed_assistant.content,
                                provider:      typed_assistant.provider,
                                model:         typed_assistant.model,
                                input_tokens:  typed_assistant.input_tokens,
                                output_tokens: typed_assistant.output_tokens)
            assistant_response = @raw_response.content
          end

          trigger_async_curation(conv_id, @request.messages, assistant_response)

          @timeline.record(
            category: :internal, key: 'context:stored',
            direction: :internal, detail: "stored to #{conv_id}",
            from: 'pipeline', to: 'conversation_store'
          )
        end

        def trigger_async_curation(conv_id, turn_messages, assistant_response)
          Context::Curator.new(conversation_id: conv_id)
                          .curate_turn(turn_messages:      turn_messages,
                                       assistant_response: assistant_response)
        rescue StandardError => e
          @warnings << "context_curation trigger failed: #{e.message}"
          handle_exception(e, level: :warn, operation: 'llm.pipeline.trigger_async_curation', conversation_id: conv_id)
        end

        def step_response_return; end

        def build_response
          @extracted_tokens ||= extract_tokens

          content = if @raw_response.respond_to?(:content)
                      @raw_response.content
                    elsif @raw_response.is_a?(Hash) && @raw_response[:content]
                      @raw_response[:content]
                    else
                      @raw_response.to_s
                    end

          msg = Types::Message.build(
            role:            :assistant,
            content:         content,
            provider:        @resolved_provider,
            model:           @resolved_model,
            input_tokens:    @extracted_tokens.respond_to?(:input_tokens) ? @extracted_tokens.input_tokens : nil,
            output_tokens:   @extracted_tokens.respond_to?(:output_tokens) ? @extracted_tokens.output_tokens : nil,
            conversation_id: @request.conversation_id
          )

          @timestamps[:returned] = Time.now

          timeline_events = @_response_timeline_snapshot || @timeline.events
          timeline_parts = @_response_participants_snapshot || @timeline.participants
          warnings_snapshot = @_response_warnings_snapshot || @warnings

          log.debug("[pipeline][build_response] action=build request_id=#{@request.id} provider=#{@resolved_provider} model=#{@resolved_model}")

          Response.build(
            request_id:      @request.id,
            conversation_id: @request.conversation_id || "conv_#{SecureRandom.hex(8)}",
            message:         msg.to_h,
            routing:         build_response_routing,
            tokens:          build_response_tokens,
            thinking:        extract_thinking,
            stop:            extract_stop_reason,
            tools:           response_tool_calls,
            stream:          @request.stream == true,
            cache:           build_response_cache,
            cost:            estimate_response_cost,
            timestamps:      @timestamps,
            enrichments:     @enrichments,
            audit:           @audit,
            timeline:        timeline_events,
            participants:    timeline_parts,
            warnings:        warnings_snapshot,
            tracing:         @tracing,
            caller:          @request.caller,
            classification:  @request.classification,
            billing:         @request.billing,
            test:            @request.test,
            quality:         @confidence_score&.to_h,
            features:        build_response_features
          )
        end

        def requested_deferred_tool_names
          return [] unless @request.respond_to?(:metadata)

          metadata = @request.metadata || {}
          requested = metadata[:requested_tools] || metadata['requested_tools'] || []
          Array(requested).map { |name| name.to_s.tr('.', '_') }.reject(&:empty?)
        end

        def build_response_routing
          routing = {
            provider: @resolved_provider,
            instance: @resolved_instance,
            model:    @resolved_model,
            tier:     @resolved_tier
          }.compact
          routing[:offering_id] = @resolved_offering_id if @resolved_offering_id
          routing[:offering_metadata] = @resolved_offering_metadata if @resolved_offering_metadata&.any?

          routing_audit = @audit[:'routing:provider_selection']
          if routing_audit.is_a?(Hash) && routing_audit[:data].is_a?(Hash)
            routing[:strategy] = routing_audit[:data][:strategy]
            routing[:tier]     = routing_audit[:data][:tier]
          end

          routing[:escalated] = @escalation_history.size > 1
          routing[:escalation_chain] = @escalation_history if @escalation_history.any?
          routing[:route_attempts] = @route_attempts.dup if @route_attempts.any?

          if @timestamps[:provider_start] && @timestamps[:provider_end]
            routing[:latency_ms] = ((@timestamps[:provider_end] - @timestamps[:provider_start]) * 1000).round
          end

          routing
        end

        def build_response_tokens
          tokens = @extracted_tokens
          return tokens unless tokens.respond_to?(:input_tokens)

          input  = tokens.input_tokens.to_i
          output = tokens.output_tokens.to_i
          result = {
            input_tokens:       input,
            output_tokens:      output,
            # Backwards-compatible aliases used by token_value/inference_token_value helpers
            input:              input,
            output:             output,
            cache_read_tokens:  tokens.respond_to?(:cache_read_tokens) ? tokens.cache_read_tokens.to_i : 0,
            cache_write_tokens: tokens.respond_to?(:cache_write_tokens) ? tokens.cache_write_tokens.to_i : 0,
            total:              input + output
          }

          context_window = @resolved_offering_metadata&.dig(:limits, :context_window) ||
                           @resolved_offering_metadata&.dig(:context_window)
          if context_window&.to_i&.positive?
            result[:context_window] = context_window.to_i
            result[:utilization]    = (result[:input_tokens].to_f / context_window.to_i).round(4)
            result[:headroom]       = context_window.to_i - result[:input_tokens]
          end

          result
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.pipeline.build_response_tokens')
          @extracted_tokens
        end

        def extract_thinking
          return nil unless @raw_response

          thinking = if @raw_response.respond_to?(:thinking) && @raw_response.thinking
                       @raw_response.thinking
                     elsif @raw_response.respond_to?(:metadata) && @raw_response.metadata.is_a?(Hash)
                       @raw_response.metadata[:thinking] || @raw_response.metadata['thinking']
                     end
          return nil unless thinking

          payload = normalize_thinking_payload(thinking)
          return nil unless payload

          payload[:config] = @request.thinking if @request.thinking
          payload
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.pipeline.extract_thinking')
          nil
        end

        def normalize_thinking_payload(thinking)
          if thinking.is_a?(Hash)
            normalized = thinking.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
            content = normalized[:content] || normalized[:text]
            signature = normalized[:signature]
          elsif thinking.respond_to?(:text)
            content = thinking.text
            signature = thinking.respond_to?(:signature) ? thinking.signature : nil
          else
            content = thinking
            signature = nil
          end
          content = content.to_s.strip unless content.nil?
          return nil if content.to_s.empty? && signature.to_s.empty?

          { content: content, signature: signature, enabled: true }.compact
        end

        def build_response_cache
          return {} unless @extracted_tokens

          cache_read  = @extracted_tokens.respond_to?(:cache_read_tokens) ? @extracted_tokens.cache_read_tokens.to_i : 0
          cache_write = @extracted_tokens.respond_to?(:cache_write_tokens) ? @extracted_tokens.cache_write_tokens.to_i : 0
          return {} if cache_read.zero? && cache_write.zero?

          {
            read_tokens:  cache_read,
            write_tokens: cache_write,
            hit:          cache_read.positive?,
            strategy:     @request.respond_to?(:cache) ? @request.cache : nil
          }
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.pipeline.build_response_cache')
          {}
        end

        def build_response_features
          features = {}
          features[:thinking]       = true if @request.thinking
          features[:streaming]      = true if @request.stream == true
          features[:tools]          = true if response_tool_calls&.any?
          features[:prompt_caching] = true if @extracted_tokens.respond_to?(:cache_read_tokens) &&
                                              (@extracted_tokens.cache_read_tokens.to_i.positive? ||
                                               @extracted_tokens.cache_write_tokens.to_i.positive?)
          features[:enrichments]    = true if @enrichments&.any?
          features.empty? ? nil : features
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.pipeline.build_response_features')
          nil
        end

        def extract_stop_reason
          reason = if @raw_response.respond_to?(:stop_reason)
                     @raw_response.stop_reason&.to_sym
                   elsif @raw_response.respond_to?(:tool_calls) && @raw_response.tool_calls&.any?
                     :tool_use
                   end
          { reason: reason || :end_turn }
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.extract_stop_reason')
          { reason: :end_turn }
        end

        def estimate_response_cost
          @extracted_tokens ||= extract_tokens
          input  = @extracted_tokens.respond_to?(:input_tokens) ? @extracted_tokens.input_tokens : @extracted_tokens[:input].to_i
          output = @extracted_tokens.respond_to?(:output_tokens) ? @extracted_tokens.output_tokens : @extracted_tokens[:output].to_i
          return {} unless @resolved_model && (input + output).positive?

          estimated = Metering::Pricing.estimate(
            model_id:      @resolved_model,
            input_tokens:  input,
            output_tokens: output
          )
          { estimated_usd: estimated, provider: @resolved_provider, model: @resolved_model }
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.estimate_response_cost')
          {}
        end

        def response_tool_calls
          # Prefer typed ToolCall objects from pending history (already built during execution)
          typed_from_history = @pending_tool_history
                               .filter_map { |entry| entry[:typed_call] }
          return typed_from_history if typed_from_history.any?

          return [] unless @raw_response.respond_to?(:tool_calls) && @raw_response.tool_calls

          tool_timeline = build_tool_timeline_index

          Array(@raw_response.tool_calls).map do |tool_call|
            tc_id   = tool_call[:id] || tool_call['id']
            tc_name = tool_call[:name] || tool_call['name']
            tc_args = tool_call[:arguments] || tool_call['arguments'] || {}

            timeline_data = tool_timeline[tc_name] || {}

            Types::ToolCall.build(
              id:          tc_id,
              name:        tc_name,
              arguments:   tc_args,
              exchange_id: timeline_data[:exchange_id],
              source:      timeline_data[:source],
              status:      timeline_data[:status],
              duration_ms: timeline_data[:duration_ms],
              result:      timeline_data[:result]
            )
          end
        end

        def build_tool_timeline_index
          index = {}
          @timeline.events.each do |event|
            key = event[:key]
            data = event[:data] || {}

            if key&.start_with?('tool:execute:')
              tool_name = key.sub('tool:execute:', '')
              index[tool_name] = {
                exchange_id: event[:exchange_id],
                source:      data[:source],
                status:      data[:status],
                duration_ms: event[:duration_ms]
              }
            elsif key&.start_with?('tool:result:')
              tool_name = key.sub('tool:result:', '')
              index[tool_name][:result] = data[:result] if index[tool_name]
            end
          end

          index
        end
      end
    end
  end
end
