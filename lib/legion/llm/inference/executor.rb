# frozen_string_literal: true

require 'concurrent'

module Legion
  module LLM
    module Inference
      class Executor
        include Legion::Logging::Helper
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
          @resolved_model = nil
          @resolved_offering_id = nil
          @resolved_offering_metadata = {}
          @confidence_score = nil
          @escalation_chain = nil
          @escalation_history = []
          @proactive_tier_assignment = nil
          @tool_event_handler = nil
          @sticky_turn_snapshot = nil
          @pending_tool_history = Concurrent::Array.new
          @pending_tool_history_mutex = Mutex.new
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

        def execute_steps
          executed = 0
          skipped = 0
          pipeline_start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          step_timings = []
          STEPS.each do |step|
            if Profile.skip?(@profile, step)
              skipped += 1
              next
            end

            t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            execute_step(step) { send(:"step_#{step}") }
            elapsed_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - t0) * 1000).round
            step_timings << "#{step}=#{elapsed_ms}ms"
            executed += 1
          end
          total_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - pipeline_start) * 1000).round
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
          provider = @request.routing[:provider]
          model = @request.routing[:model]
          offering_id = @request.routing[:offering_id] || @request.routing[:id]
          offering_metadata = normalize_offering_metadata(@request.routing[:offering_metadata] ||
                                                          @request.routing[:offering])
          intent = @request.extra[:intent]
          tier = @request.extra[:tier]

          # Consume proactive tier assignment when no explicit tier/intent provided by caller
          if @proactive_tier_assignment && !tier && !intent
            tier = @proactive_tier_assignment[:tier]
            intent = @proactive_tier_assignment[:intent]
          end

          if (intent || tier) && defined?(Router) && Router.routing_enabled?
            resolution = if pipeline_escalation_enabled?
                           @escalation_chain = Router.resolve_chain(
                             intent:          intent,
                             tier:            tier,
                             model:           model,
                             provider:        provider,
                             max_escalations: pipeline_escalation_max_attempts
                           )
                           @escalation_chain.primary
                         else
                           Router.resolve(intent: intent, tier: tier, model: model, provider: provider)
                         end
            if resolution
              provider = resolution.provider
              model = resolution.model
              offering_id = resolution.offering_id || offering_id
              offering_metadata = resolution.offering_metadata unless resolution.offering_metadata.empty?
              @audit[:'routing:provider_selection'] = {
                outcome: :success,
                detail: "selected #{provider}:#{model} via #{resolution.rule}",
                data: { strategy: resolution.rule, tier: resolution.tier, offering_id: offering_id,
                        offering_metadata: offering_metadata }.compact,
                duration_ms: 0, timestamp: Time.now
              }
            end
          end

          @resolved_provider = provider ||
                               (model && Router.infer_provider_for_model(model)) ||
                               llm_setting(:default_provider)
          @resolved_model = model || llm_setting(:default_model)
          @resolved_offering_id = offering_id
          @resolved_offering_metadata = offering_metadata

          log.info "[llm][inference] resolved provider=#{@resolved_provider} model=#{@resolved_model} offering_id=#{@resolved_offering_id}"
          @timeline.record(
            category: :audit, key: 'routing:provider_selection',
            direction: :internal, detail: "routed to #{@resolved_provider}:#{@resolved_model}",
            from: 'router', to: 'pipeline'
          )
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

        def run_provider_call_with_escalation
          chain = @escalation_chain || build_default_escalation_chain
          threshold = pipeline_escalation_quality_threshold
          quality_check = @request.extra[:quality_check]
          succeeded = false
          log.debug "[llm][executor] action=escalation.enter chain_size=#{chain.size} threshold=#{threshold}"

          chain.each do |resolution|
            start_time = Time.now
            @resolved_provider = resolution.provider
            @resolved_model = resolution.model
            @resolved_offering_id = resolution.offering_id
            @resolved_offering_metadata = resolution.offering_metadata
            succeeded = attempt_escalation(resolution, threshold, quality_check, start_time)
            break if succeeded
          rescue Legion::LLM::AuthError, Legion::LLM::PrivacyModeError => e
            record_escalation_failure(e, resolution, start_time,
                                      outcome: :auth_error, operation: 'llm.pipeline.escalation_attempt.auth',
                                      handled: true)
          rescue Legion::LLM::RateLimitError => e
            record_escalation_failure(e, resolution, start_time,
                                      outcome: :rate_limited, operation: 'llm.pipeline.escalation_attempt.rate_limit',
                                      handled: true)
          rescue StandardError => e
            record_escalation_failure(e, resolution, start_time, outcome:   :error,
                                                                 operation: 'llm.pipeline.escalation_attempt')
          end
          return if succeeded

          emit_error_audit(
            EscalationExhausted.new("All #{@escalation_history.size} attempts failed"),
            status: 'escalation_exhausted'
          )
          raise EscalationExhausted, "All #{@escalation_history.size} escalation attempts failed"
        end

        def attempt_escalation(resolution, threshold, quality_check, start_time)
          execute_provider_request
          duration_ms = ((Time.now - start_time) * 1000).round
          result = Quality::Checker.check(@raw_response, quality_threshold: threshold, quality_check: quality_check)
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
          result.passed
        end

        def record_escalation_failure(err, resolution, start_time, outcome:, operation:, handled: false)
          duration_ms = ((Time.now - start_time) * 1000).round
          handle_exception(err, level: :warn, handled: handled, operation: operation,
                               provider: resolution.provider, model: resolution.model, duration_ms: duration_ms)
          Router.health_tracker.report(provider: resolution.provider, offering_id: resolution.offering_id,
                                       signal: :error, value: 1,
                                       metadata: { reason: err.class.name, message: err.message })
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
          Router.resolve_chain(max_escalations: pipeline_escalation_max_attempts)
        end

        def escalation_attempt_hash(resolution, outcome:, failures:, duration_ms:)
          attempt = { model: resolution.model, provider: resolution.provider, tier: resolution.tier,
                      outcome: outcome, failures: failures, duration_ms: duration_ms }
          attempt[:offering_id] = resolution.offering_id if resolution.offering_id
          attempt[:offering_metadata] = resolution.offering_metadata unless resolution.offering_metadata.empty?
          attempt
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

          raise Legion::LLM::ProviderError, "Native provider not registered: #{@resolved_provider}" unless use_native_dispatch?(@resolved_provider)

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
          injected_system = EnrichmentInjector.inject(
            system:      @request.system,
            enrichments: @enrichments
          )

          options = {
            system:            injected_system,
            offering_id:       @resolved_offering_id,
            offering_metadata: @resolved_offering_metadata
          }
          options[:tools] = native_dispatch_tools if native_dispatch_tools.any?
          options.compact
        end

        def native_dispatch_chat_options
          opts = {
            model:    @resolved_model,
            provider: @resolved_provider
          }
          opts[:thinking] = @request.thinking if @request.thinking
          opts.compact
        end

        def execute_native_tool_loop
          messages = native_dispatch_messages.dup
          max_rounds = llm_setting(:max_tool_rounds, MAX_NATIVE_TOOL_ROUNDS).to_i
          max_rounds = MAX_NATIVE_TOOL_ROUNDS unless max_rounds.positive?
          round = 0
          log.debug "[llm][executor] action=native_tool_loop.enter max_rounds=#{max_rounds} messages=#{messages.size}"

          loop do
            result = Call::Dispatch.dispatch_chat(
              provider: @resolved_provider,
              model:    @resolved_model,
              messages: messages,
              **native_dispatch_options
            )
            result = Call::NativeResponseAdapter.coerce_result(result)
            tool_calls = Array(result[:tool_calls]).map { |tool_call| normalize_native_tool_call(tool_call) }
            if tool_calls.empty?
              log.debug "[llm][executor] action=native_tool_loop.complete rounds=#{round} reason=no_tool_calls"
              return result
            end

            round += 1
            tool_names = tool_calls.map { |tc| tc[:name] }.join(',')
            log.debug "[llm][executor] action=native_tool_loop.round round=#{round} tool_count=#{tool_calls.size} tools=#{tool_names}"
            raise Legion::LLM::PipelineError, "tool loop exceeded #{max_rounds} rounds" if round > max_rounds

            messages << native_assistant_tool_message(result, tool_calls)
            tool_calls.each do |tool_call|
              messages << native_tool_result_message(tool_call, dispatch_native_tool_call(tool_call, round))
            end
          end
        end

        def native_dispatch_tools
          @native_dispatch_tools ||= native_tool_definitions.to_h { |tool| [tool.name.to_sym, tool.to_h] }
        end

        def native_tool_definitions
          @native_tool_definitions ||= begin
            definitions = []
            Array(@request.tools).each { |tool| add_native_tool_definition(definitions, tool) }
            add_registry_tool_definitions(definitions) unless @request.tools.is_a?(Array) && @request.tools.empty?
            log.debug "[llm][executor] action=native_tool_definitions.built count=#{definitions.size}"
            definitions
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
          return unless Legion::Settings::Extensions.respond_to?(:tools) &&
                        Legion::Settings::Extensions.respond_to?(:filter_tools) &&
                        Array(Legion::Settings::Extensions.tools).any?

          add_settings_extensions_tool_definitions(definitions)
        rescue StandardError => e
          @warnings << "Tool definition error: #{e.message}"
          handle_exception(e, level: :warn, operation: 'llm.pipeline.native_registry_tools')
        end

        def add_settings_extensions_tool_definitions(definitions)
          injected_names = definitions.map(&:name)
          inject_limit = registry_tool_limit

          always_entries = Legion::Settings::Extensions.filter_tools(deferred: false)
          gaia_entries = gaia_advisory_tool_entries
          triggered_entries = @triggered_tools.any? ? Array(@triggered_tools) : []
          prioritized = if local_provider?
                          gaia_entries + triggered_entries + always_entries
                        else
                          always_entries + gaia_entries + triggered_entries
                        end

          prioritized.each do |entry|
            break if inject_limit && injected_names.size >= inject_limit

            definition = if entry.is_a?(Hash) && entry[:name]
                           Types::ToolDefinition.from_registry_entry(entry)
                         else
                           Types::ToolDefinition.from_tool_class(entry)
                         end
            next if gaia_tool_suppressed?(definition.name)
            next if injected_names.include?(definition.name)

            tool_class = entry.is_a?(Hash) ? entry[:tool_class] : entry
            @injected_tool_map[definition.name] = tool_class if tool_class
            @native_tool_source_map[definition.name] = definition.source
            definitions << definition
            injected_names << definition.name
          end

          add_requested_deferred_tool_definitions_from_settings(definitions, injected_names)
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

        def gaia_advisory_tool_entries
          hint_names = gaia_tool_hint_names
          return [] if hint_names.empty?
          return [] unless Legion::Settings::Extensions.respond_to?(:filter_tools)

          entries = Legion::Settings::Extensions.filter_tools(deferred: false) +
                    Legion::Settings::Extensions.filter_tools(deferred: true)
          entries.each_with_object([]) do |entry, selected|
            name = normalized_tool_name(registry_entry_name(entry))
            next unless hint_names.include?(name)
            next if gaia_tool_suppressed?(name)
            next if selected.any? { |existing| normalized_tool_name(registry_entry_name(existing)) == name }

            selected << entry
          end
        end

        def gaia_tool_hint_names
          Array(gaia_advisory_value(:tool_hint)).filter_map do |name|
            normalized = normalized_tool_name(name)
            normalized unless normalized.empty?
          end
        end

        def gaia_suppressed_tool_names
          @gaia_suppressed_tool_names ||= Array(gaia_advisory_value(:suppress)).filter_map do |name|
            normalized = normalized_tool_name(name)
            normalized unless normalized.empty?
          end
        end

        def gaia_tool_suppressed?(name)
          gaia_suppressed_tool_names.include?(normalized_tool_name(name))
        end

        def gaia_advisory_value(key)
          data = gaia_advisory_data
          return nil unless data.respond_to?(:key?)

          data[key] || data[key.to_s]
        end

        def gaia_advisory_data
          enrichment = @enrichments['gaia:advisory']
          return {} unless enrichment.respond_to?(:key?)

          enrichment[:data] || enrichment['data'] || {}
        end

        def registry_entry_name(entry)
          if entry.is_a?(Hash)
            entry[:name] || entry['name']
          elsif entry.respond_to?(:tool_name)
            entry.tool_name
          elsif entry.respond_to?(:name)
            entry.name
          end
        end

        def normalized_tool_name(name)
          name.to_s.tr('.', '_')
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
          normalized[:arguments] ||= {}
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

        def step_provider_call_stream(&)
          providers_tried = []
          begin
            execute_provider_request_stream(&)
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

          raise Legion::LLM::ProviderError, "Native provider not registered: #{@resolved_provider}" unless use_native_dispatch?(@resolved_provider)

          execute_provider_request_stream_native(&)

          @timestamps[:provider_end] = Time.now
          record_provider_response
        end

        def execute_provider_request_stream_native(&)
          result = Call::Dispatch.dispatch_stream(
            provider: @resolved_provider,
            model:    @resolved_model,
            messages: native_dispatch_messages,
            **native_dispatch_options,
            &
          )
          merge_response_offering_metadata(result[:metadata])
          @raw_response = Call::NativeResponseAdapter.new(result)
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
          Legion::LLM::Audit.emit_tools(
            request_id:      @request.id,
            conversation_id: @request.conversation_id,
            exchange_id:     @exchange_id,
            tool_name:       tc_name,
            tool_call:       {
              id:          tc_id,
              name:        tc_name,
              status:      is_error ? :error : :success,
              duration_ms: duration_ms,
              started_at:  started_at,
              finished_at: finished_at
            },
            result:          result_str[0, 4096],
            caller:          @request.caller,
            classification:  @request.classification,
            tracing:         @tracing,
            timestamp:       finished_at,
            request_type:    'tool'
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.publish_tool_audit', tool_name: tc_name)
        end

        def tool_call_field(tool_call, field)
          return tool_call.public_send(field) if tool_call.respond_to?(field)

          tool_call[field]
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.pipeline.tool_call_field', field: field)
          nil
        end

        def execute_step(name, &block)
          return block.call unless pipeline_spans_enabled?

          block_called = false
          begin
            Legion::Telemetry.with_span("pipeline.#{name}", kind: :internal) do |span|
              block_called = true
              result = block.call
              annotate_span(span, name)
              result
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.with_step_span', step: name, block_called: block_called)
            raise if block_called

            block.call
          end
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
            request_id:        @request.id,
            caller:            @request.caller
          )
          Steps::Metering.publish_or_spool(event)
        rescue StandardError => e
          @warnings << "metering error: #{e.message}"
          handle_exception(e, level: :warn, operation: 'llm.pipeline.step_metering')
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
          routing = { provider: @resolved_provider, model: @resolved_model }
          routing[:offering_id] = @resolved_offering_id if @resolved_offering_id
          routing[:offering_metadata] = @resolved_offering_metadata if @resolved_offering_metadata&.any?

          routing_audit = @audit[:'routing:provider_selection']
          if routing_audit.is_a?(Hash) && routing_audit[:data].is_a?(Hash)
            routing[:strategy] = routing_audit[:data][:strategy]
            routing[:tier]     = routing_audit[:data][:tier]
          end

          routing[:escalated] = @escalation_history.size > 1
          routing[:escalation_chain] = @escalation_history if @escalation_history.any?

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

          thinking_content = if @raw_response.respond_to?(:thinking) && @raw_response.thinking
                               @raw_response.thinking
                             elsif @raw_response.respond_to?(:metadata) && @raw_response.metadata.is_a?(Hash)
                               @raw_response.metadata[:thinking] || @raw_response.metadata['thinking']
                             end
          return nil unless thinking_content

          {
            content: thinking_content,
            enabled: true,
            config:  @request.thinking
          }
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.pipeline.extract_thinking')
          nil
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
