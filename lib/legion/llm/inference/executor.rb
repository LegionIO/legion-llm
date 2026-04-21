# frozen_string_literal: true

require 'concurrent'

module Legion
  module LLM
    module Pipeline
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

        MAX_RUBY_LLM_TOOL_ROUNDS = 200

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
          @confidence_score = nil
          @escalation_chain = nil
          @escalation_history = []
          @proactive_tier_assignment = nil
          @tool_event_handler = nil
          @sticky_turn_snapshot = nil
          @pending_tool_history = Concurrent::Array.new
          @pending_tool_history_mutex = Mutex.new
          @injected_tool_map = {}
          @freshly_triggered_keys = []
        end

        def call
          execute_steps
          build_response
        end

        def call_stream(&block)
          return call unless block

          execute_pre_provider_steps
          step_provider_call_stream(&block)
          execute_post_provider_steps
          build_response
        end

        private

        def inject_registry_tools(session)
          return unless defined?(::Legion::Tools::Registry)

          injected_names = []

          # Always-loaded tools — inject all unconditionally
          ::Legion::Tools::Registry.tools.each do |tool_class|
            adapter = ToolAdapter.new(tool_class)
            @injected_tool_map[adapter.name] = tool_class
            session.with_tool(adapter)
            injected_names << adapter.name
          rescue StandardError => e
            @warnings << "Failed to inject always tool: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.inject_always_tool')
          end

          # Trigger-matched tools — inject tools surfaced by trigger word matching
          if @triggered_tools.any?
            @triggered_tools.each do |tool_class|
              adapter = ToolAdapter.new(tool_class)
              next if injected_names.include?(adapter.name)

              @injected_tool_map[adapter.name] = tool_class
              session.with_tool(adapter)
              injected_names << adapter.name
            rescue StandardError => e
              @warnings << "Failed to inject triggered tool: #{e.message}"
              handle_exception(e, level: :warn, operation: 'llm.pipeline.inject_triggered_tool')
            end
          end

          # Requested deferred tools — inject only if explicitly requested
          deferred = ::Legion::Tools::Registry.respond_to?(:deferred_tools) ? ::Legion::Tools::Registry.deferred_tools : []
          requested = requested_deferred_tool_names
          if requested.any?
            deferred.each do |tool_class|
              adapter = ToolAdapter.new(tool_class)
              next unless requested.include?(adapter.name)

              @injected_tool_map[adapter.name] = tool_class
              session.with_tool(adapter)
              injected_names << adapter.name
            rescue StandardError => e
              @warnings << "Failed to inject deferred tool: #{e.message}"
              handle_exception(e, level: :warn, operation: 'llm.pipeline.inject_deferred_tool')
            end
          end

          log.info(
            "[llm][tools] inject request_id=#{@request.id} " \
            "always=#{::Legion::Tools::Registry.tools.size} " \
            "triggered=#{@triggered_tools.size} " \
            "deferred_available=#{deferred.size} " \
            "requested_deferred=#{requested.size} " \
            "injected=#{injected_names.size} names=#{injected_names.first(25).join(',')}"
          )
        rescue StandardError => e
          @warnings << "Tool injection error: #{e.message}"
          handle_exception(e, level: :warn, operation: 'llm.pipeline.inject_tools')
        end

        # Backwards compatibility alias
        alias inject_discovered_tools inject_registry_tools

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
          @tracing = Tracing.init(existing: @request.tracing)
          @timeline.record(
            category: :internal, key: 'tracing:init',
            direction: :internal, detail: 'trace initialized',
            from: 'pipeline', to: 'pipeline'
          )
        end

        def step_idempotency; end

        def step_conversation_uuid
          return if @request.conversation_id

          @request = @request.with(conversation_id: "conv_#{SecureRandom.hex(8)}")
        end

        def step_context_load
          conv_id = @request.conversation_id
          return unless conv_id

          history = ConversationStore.messages(conv_id)
          return if history.empty?

          curator = ContextCurator.new(conversation_id: conv_id)
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
          conv_settings = Legion::LLM.settings[:conversation] || {}
          return history unless conv_settings[:auto_compact]

          threshold = conv_settings[:summarize_threshold] || 50_000
          target_tokens = conv_settings[:target_tokens] || 20_000
          preserve_recent = conv_settings[:preserve_recent] || 10

          estimated = Compressor.estimate_tokens(history)
          return history unless estimated >= threshold

          compact = Compressor.auto_compact(
            history,
            target_tokens:   target_tokens,
            preserve_recent: preserve_recent
          )

          ConversationStore.replace(conv_id, compact)

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
          @timestamps[:routing_start] = Time.now
          provider = @request.routing[:provider]
          model = @request.routing[:model]
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
              @audit[:'routing:provider_selection'] = {
                outcome: :success,
                detail: "selected #{provider}:#{model} via #{resolution.rule}",
                data: { strategy: resolution.rule, tier: resolution.tier },
                duration_ms: 0, timestamp: Time.now
              }
            end
          end

          @resolved_provider = provider || Legion::LLM.settings[:default_provider]
          @resolved_model = model || Legion::LLM.settings[:default_model]

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
          if pipeline_escalation_enabled?
            run_provider_call_with_escalation
          else
            run_provider_call_single
          end
        end

        def run_provider_call_single
          providers_tried = []
          begin
            execute_provider_request
          rescue RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError,
                 Faraday::UnauthorizedError, Faraday::ForbiddenError => e
            providers_tried << @resolved_provider
            fallback = find_fallback_provider(exclude: providers_tried)
            handle_exception(
              e,
              level:             :warn,
              operation:         'llm.pipeline.provider_call.auth',
              provider:          @resolved_provider,
              model:             @resolved_model,
              fallback_provider: fallback&.dig(:provider)
            )
            if fallback
              log.warn "[pipeline] #{@resolved_provider} auth failed (#{e.class}), falling back to #{fallback[:provider]}:#{fallback[:model]}"
              from_provider = @resolved_provider
              from_model = @resolved_model
              @resolved_provider = fallback[:provider]
              @resolved_model = fallback[:model]
              @warnings << { type: :provider_fallback, original_error: e.message, fallback: "#{@resolved_provider}:#{@resolved_model}" }
              @tool_event_handler&.call(
                type: :model_fallback,
                from_provider: from_provider, to_provider: @resolved_provider,
                from_model: from_model, to_model: @resolved_model,
                error: e.message, reason: 'auth_failed'
              )
              @timeline.record(
                category: :provider, key: 'provider:fallback',
                direction: :internal,
                detail: "auth failed on #{providers_tried.last}, trying #{@resolved_provider}",
                from: 'pipeline', to: "provider:#{@resolved_provider}"
              )
              retry
            end
            raise Legion::LLM::AuthError, e.message
          rescue RubyLLM::RateLimitError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.rate_limit',
                              provider: @resolved_provider, model: @resolved_model)
            raise Legion::LLM::RateLimitError, e.message
          rescue RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError,
                 Faraday::ServerError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.provider_error',
                              provider: @resolved_provider, model: @resolved_model)
            raise Legion::LLM::ProviderError, e.message
          rescue Faraday::TooManyRequestsError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.http_rate_limit',
                              provider: @resolved_provider, model: @resolved_model)
            raise Legion::LLM::RateLimitError.new(e.message, retry_after: extract_retry_after(e))
          rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call.provider_down',
                              provider: @resolved_provider, model: @resolved_model)
            raise Legion::LLM::ProviderDown, e.message
          end
        end

        def run_provider_call_with_escalation
          chain = @escalation_chain || build_default_escalation_chain
          threshold = pipeline_escalation_quality_threshold
          quality_check = @request.extra[:quality_check]
          succeeded = false

          # rubocop:disable Metrics/BlockLength
          chain.each do |resolution|
            start_time = Time.now
            begin
              @resolved_provider = resolution.provider
              @resolved_model = resolution.model
              execute_provider_request

              duration_ms = ((Time.now - start_time) * 1000).round
              result = QualityChecker.check(@raw_response, quality_threshold: threshold,
                                                           quality_check:     quality_check)

              @timeline.record(
                category: :provider, key: 'escalation:attempt',
                direction: :internal,
                detail: "attempt #{@escalation_history.size + 1}: #{resolution.provider}:#{resolution.model} => #{result.passed ? :success : :quality_failure}",
                from: 'pipeline', to: "provider:#{resolution.provider}"
              )

              if result.passed
                @escalation_history << { model: resolution.model, provider: resolution.provider,
                                         tier: resolution.tier, outcome: :success,
                                         failures: [], duration_ms: duration_ms }
                succeeded = true
                break
              else
                @escalation_history << { model: resolution.model, provider: resolution.provider,
                                         tier: resolution.tier, outcome: :quality_failure,
                                         failures: result.failures, duration_ms: duration_ms }
              end
            rescue Legion::LLM::AuthError, Legion::LLM::RateLimitError, Legion::LLM::PrivacyModeError
              raise
            rescue StandardError => e
              duration_ms = ((Time.now - start_time) * 1000).round
              handle_exception(e, level: :warn, operation: 'llm.pipeline.escalation_attempt',
                                  provider: resolution.provider, model: resolution.model, duration_ms: duration_ms)
              @escalation_history << { model: resolution.model, provider: resolution.provider,
                                       tier: resolution.tier, outcome: :error,
                                       failures: [e.class.name], duration_ms: duration_ms }
              @timeline.record(
                category: :provider, key: 'escalation:attempt',
                direction: :internal,
                detail: "attempt #{@escalation_history.size}: #{resolution.provider}:#{resolution.model} => error: #{e.message}",
                from: 'pipeline', to: "provider:#{resolution.provider}"
              )
            end
          end
          # rubocop:enable Metrics/BlockLength

          raise EscalationExhausted, "All #{@escalation_history.size} escalation attempts failed" unless succeeded
        end

        def build_default_escalation_chain
          Router.resolve_chain(max_escalations: pipeline_escalation_max_attempts)
        end

        def pipeline_escalation_enabled?
          routing = Legion::LLM.settings[:routing]
          return false unless routing.is_a?(Hash)

          esc = routing[:escalation] || {}
          esc[:enabled] == true && esc[:pipeline_enabled] == true
        end

        def pipeline_escalation_max_attempts
          routing = Legion::LLM.settings[:routing]
          return 3 unless routing.is_a?(Hash)

          esc = routing[:escalation] || {}
          esc.fetch(:max_attempts, 3)
        end

        def pipeline_escalation_quality_threshold
          routing = Legion::LLM.settings[:routing]
          return 50 unless routing.is_a?(Hash)

          esc = routing[:escalation] || {}
          esc.fetch(:quality_threshold, 50)
        end

        def execute_provider_request
          @timestamps[:provider_start] = Time.now
          @timeline.record(
            category: :provider, key: 'provider:request_sent',
            exchange_id: @exchange_id, direction: :outbound,
            detail: "calling #{@resolved_provider}",
            from: 'pipeline', to: "provider:#{@resolved_provider}"
          )

          if use_native_dispatch?(@resolved_provider)
            execute_provider_request_native
          else
            execute_provider_request_ruby_llm
          end

          @timestamps[:provider_end] = Time.now
          record_provider_response
        end

        def execute_provider_request_ruby_llm
          session, message_content = build_ruby_llm_session
          install_tool_loop_guard(session)
          @raw_response = message_content ? session.ask(message_content) : session
        end

        def execute_provider_request_native
          injected_system = EnrichmentInjector.inject(
            system:      @request.system,
            enrichments: @enrichments
          )

          messages = apply_conversation_breakpoint(@request.messages)

          opts = { system: injected_system }.compact

          begin
            result = NativeDispatch.dispatch_chat(
              provider: @resolved_provider,
              model:    @resolved_model,
              messages: messages,
              **opts
            )
            @raw_response = NativeResponseAdapter.new(result)
          rescue Legion::LLM::ProviderError => e
            layer_settings = Legion::LLM.settings[:provider_layer] || {}
            raise unless layer_settings.fetch(:fallback_to_ruby_llm, true)

            handle_exception(
              e,
              level:     :warn,
              operation: 'llm.pipeline.native_dispatch',
              provider:  @resolved_provider,
              fallback:  'ruby_llm'
            )
            execute_provider_request_ruby_llm
          end
        end

        def use_native_dispatch?(provider)
          return false unless defined?(NativeDispatch)

          layer_settings = Legion::LLM.settings[:provider_layer] || {}
          mode = layer_settings.fetch(:mode, 'ruby_llm').to_s

          case mode
          when 'native'
            true
          when 'auto'
            NativeDispatch.available?(provider)
          else
            false
          end
        end

        def record_provider_response
          @timeline.record(
            category: :provider, key: 'provider:response_received',
            exchange_id: @exchange_id, direction: :inbound,
            detail: 'response received',
            from: "provider:#{@resolved_provider}", to: 'pipeline',
            duration_ms: ((@timestamps[:provider_end] - @timestamps[:provider_start]) * 1000).to_i
          )
        end

        def extract_retry_after(error)
          return nil unless error.respond_to?(:response) && error.response.is_a?(Hash)

          error.response[:headers]&.fetch('retry-after', nil)&.to_i
        end

        def execute_pre_provider_steps
          PRE_PROVIDER_STEPS.each do |step|
            next if Profile.skip?(@profile, step)

            execute_step(step) { send(:"step_#{step}") }
          end
        end

        def execute_post_provider_steps
          if async_post_enabled?
            execute_post_provider_steps_mixed
          else
            POST_PROVIDER_STEPS.each do |step|
              next if Profile.skip?(@profile, step)

              execute_step(step) { send(:"step_#{step}") }
            end
          end
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
          Legion::LLM.settings[:pipeline_async_post_steps] == true
        end

        private :async_post_enabled?

        def step_provider_call_stream(&)
          providers_tried = []
          begin
            execute_provider_request_stream(&)
          rescue RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError,
                 Faraday::UnauthorizedError, Faraday::ForbiddenError => e
            providers_tried << @resolved_provider
            fallback = find_fallback_provider(exclude: providers_tried)
            handle_exception(
              e,
              level:             :warn,
              operation:         'llm.pipeline.provider_call_stream.auth',
              provider:          @resolved_provider,
              model:             @resolved_model,
              fallback_provider: fallback&.dig(:provider)
            )
            if fallback
              log.warn "[pipeline] #{@resolved_provider} stream auth failed (#{e.class}), " \
                       "falling back to #{fallback[:provider]}:#{fallback[:model]}"
              from_provider = @resolved_provider
              from_model = @resolved_model
              @resolved_provider = fallback[:provider]
              @resolved_model = fallback[:model]
              @warnings << { type: :provider_fallback, original_error: e.message, fallback: "#{@resolved_provider}:#{@resolved_model}" }
              @tool_event_handler&.call(
                type: :model_fallback,
                from_provider: from_provider, to_provider: @resolved_provider,
                from_model: from_model, to_model: @resolved_model,
                error: e.message, reason: 'auth_failed'
              )
              retry
            end
            raise Legion::LLM::AuthError, e.message
          rescue RubyLLM::RateLimitError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.rate_limit',
                              provider: @resolved_provider, model: @resolved_model)
            raise Legion::LLM::RateLimitError, e.message
          rescue RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError,
                 Faraday::ServerError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.provider_error',
                              provider: @resolved_provider, model: @resolved_model)
            raise Legion::LLM::ProviderError, e.message
          rescue Faraday::TooManyRequestsError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.http_rate_limit',
                              provider: @resolved_provider, model: @resolved_model)
            raise Legion::LLM::RateLimitError.new(e.message, retry_after: extract_retry_after(e))
          rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.provider_call_stream.provider_down',
                              provider: @resolved_provider, model: @resolved_model)
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

          session, message_content = build_ruby_llm_session
          install_tool_loop_guard(session)

          Thread.current[:legion_tool_event_handler] = @tool_event_handler
          begin
            @raw_response = message_content ? session.ask(message_content, &) : session
          ensure
            Thread.current[:legion_tool_event_handler] = nil
            Thread.current[:legion_current_tool_call_id] = nil
            Thread.current[:legion_current_tool_name] = nil
            Thread.current[:legion_current_tool_started_at] = nil
          end

          @timestamps[:provider_end] = Time.now
          record_provider_response
        end

        def build_ruby_llm_session
          session = RubyLLM.chat(**ruby_llm_chat_options)

          inject_ruby_llm_tools(session)
          apply_ruby_llm_instructions(session)

          messages = apply_conversation_breakpoint(@request.messages)
          add_ruby_llm_prior_messages(session, messages)

          [session, messages.last&.dig(:content)]
        end

        def ruby_llm_chat_options
          opts = {
            model:    @resolved_model,
            provider: @resolved_provider
          }
          opts[:thinking] = @request.thinking if @request.thinking
          opts.compact
        end

        def inject_ruby_llm_tools(session)
          (@request.tools || []).each do |tool|
            session.with_tool(tool)
          end

          # nil means caller did not specify tools — inject registry tools as normal.
          # An explicit empty array [] means caller opted out of registry injection.
          return if @request.tools.is_a?(Array) && @request.tools.empty?

          inject_registry_tools(session)
        end

        def install_tool_loop_guard(session)
          unless session.respond_to?(:on_tool_call)
            log.warn('[pipeline] tool loop guard unavailable: ruby_llm session does not respond to on_tool_call')
            return
          end

          max_rounds = Legion::LLM.settings[:max_tool_rounds] || MAX_RUBY_LLM_TOOL_ROUNDS
          tool_round = 0
          session.on_tool_call do |tool_call|
            tool_round += 1
            if tool_round > max_rounds
              log.warn("[pipeline] tool loop cap hit: #{tool_round} rounds, halting")
              raise Legion::LLM::PipelineError, "tool loop exceeded #{max_rounds} rounds"
            end

            emit_tool_call_event(tool_call, tool_round)
          end

          # Wire up tool-result events so the API SSE stream can notify the
          # frontend when each tool finishes (clears the RUNNING state in the UI).
          return unless session.respond_to?(:on_tool_result)

          session.on_tool_result do |tool_result|
            emit_tool_result_event(tool_result)
          end
        end

        def emit_tool_call_event(tool_call, round)
          tc_id   = tool_call_field(tool_call, :id)
          tc_name = tool_call_field(tool_call, :name)
          tc_args = tool_call_field(tool_call, :arguments)
          started_at = Time.now

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
              runner_key:    nil
            }
            Thread.current[:legion_current_tool_history_index] = pending_index
          end

          # Store start time per-tool-call-id so emit_tool_result_event can calculate
          # accurate wall-clock duration even when tools run in parallel threads.
          Thread.current[:legion_current_tool_call_id] = tc_id
          Thread.current[:legion_current_tool_name] = tc_name
          Thread.current[:legion_current_tool_started_at] = started_at

          @tool_event_handler&.call(
            type: :tool_call, tool_call_id: tc_id, tool_name: tc_name,
            arguments: tc_args, round: round, started_at: started_at
          )
        end

        def emit_tool_result_event(tool_result)
          # tool_result may be a raw value (String/Hash) or a ToolResultWrapper
          # from our parallel patch — extract the fields defensively.
          tc_id      = tool_result.respond_to?(:tool_call_id) ? tool_result.tool_call_id : Thread.current[:legion_current_tool_call_id]
          tc_name    = tool_result.respond_to?(:tool_name)    ? tool_result.tool_name    : Thread.current[:legion_current_tool_name]
          started_at = tool_result.respond_to?(:started_at)   ? tool_result.started_at   : Thread.current[:legion_current_tool_started_at]
          finished_at = Time.now
          raw = tool_result.respond_to?(:result) ? tool_result.result : tool_result

          @pending_tool_history_mutex.synchronize do
            entry = @pending_tool_history.find { |e| e[:tool_call_id] == tc_id && e[:result].nil? }
            entry ||= @pending_tool_history[Thread.current[:legion_current_tool_history_index]]
            if entry
              entry[:result] = raw.is_a?(String) ? raw : raw.to_s
              entry[:error]  = raw.is_a?(Hash) && (raw[:error] || raw['error']) ? true : false
            end
          end

          duration_ms = started_at ? ((finished_at - started_at) * 1000).round : nil

          log.info("[pipeline][tool-result] id=#{tc_id} tool=#{tc_name} duration_ms=#{duration_ms}")

          result_str = (raw.is_a?(String) ? raw : raw.to_s)[0, 4096]

          @tool_event_handler&.call(
            type: :tool_result, tool_call_id: tc_id, tool_name: tc_name,
            result: result_str, result_size: (raw.is_a?(String) ? raw : raw.to_s).bytesize,
            started_at: started_at, finished_at: finished_at, duration_ms: duration_ms
          )
        end

        def tool_call_field(tool_call, field)
          return tool_call.public_send(field) if tool_call.respond_to?(field)

          tool_call[field]
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.pipeline.tool_call_field', field: field)
          nil
        end

        def apply_ruby_llm_instructions(session)
          injected_system = EnrichmentInjector.inject(
            system:      @request.system,
            enrichments: @enrichments
          )
          return unless injected_system

          system_blocks = apply_cache_control([{ type: :text, content: injected_system }])
          session.with_instructions(system_blocks.last[:content])
        end

        def add_ruby_llm_prior_messages(session, messages)
          prior = messages.size > 1 ? messages[0..-2] : []
          prior.each { |message| session.add_message(message) }
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
            handle_exception(e, level: :debug, operation: 'llm.pipeline.with_step_span', step: name, block_called: block_called)
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

          settings = Legion::LLM.settings[:telemetry]
          return true unless settings.is_a?(Hash)

          settings.fetch(:pipeline_spans, true)
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

        def find_fallback_provider(exclude: [])
          providers = Legion::LLM.settings[:providers] || {}
          providers.each do |name, config|
            next unless config.is_a?(Hash) && config[:enabled]
            next if exclude.include?(name) || exclude.include?(name.to_s)
            next if name == :ollama
            next unless config[:default_model]

            return { provider: name, model: config[:default_model] }
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
          input_tokens  = @raw_response.respond_to?(:input_tokens)  ? @raw_response.input_tokens.to_i  : 0
          output_tokens = @raw_response.respond_to?(:output_tokens) ? @raw_response.output_tokens.to_i : 0
          tier = @audit.dig(:'routing:provider_selection', :data, :tier)
          latency_ms = if @timestamps[:provider_start] && @timestamps[:provider_end]
                         ((@timestamps[:provider_end] - @timestamps[:provider_start]) * 1000).round
                       else
                         0
                       end
          event = Steps::Metering.build_event(
            provider:      @resolved_provider,
            model_id:      @resolved_model,
            tier:          tier,
            input_tokens:  input_tokens,
            output_tokens: output_tokens,
            latency_ms:    latency_ms
          )
          Steps::Metering.publish_or_spool(event)
        rescue StandardError => e
          @warnings << "metering error: #{e.message}"
          handle_exception(e, level: :warn, operation: 'llm.pipeline.step_metering')
        end

        def step_context_store
          conv_id = @request.conversation_id
          return unless conv_id

          @request.messages.each do |msg|
            ConversationStore.append(conv_id,
                                     role:    msg[:role]&.to_sym || :user,
                                     content: msg[:content])
          end

          assistant_response = nil
          if @raw_response.respond_to?(:content) && @raw_response.content
            ConversationStore.append(conv_id,
                                     role:          :assistant,
                                     content:       @raw_response.content,
                                     provider:      @resolved_provider,
                                     model:         @resolved_model,
                                     input_tokens:  @raw_response.respond_to?(:input_tokens) ? @raw_response.input_tokens : nil,
                                     output_tokens: @raw_response.respond_to?(:output_tokens) ? @raw_response.output_tokens : nil)
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
          ContextCurator.new(conversation_id: conv_id)
                        .curate_turn(turn_messages:      turn_messages,
                                     assistant_response: assistant_response)
        rescue StandardError => e
          @warnings << "context_curation trigger failed: #{e.message}"
          handle_exception(e, level: :warn, operation: 'llm.pipeline.trigger_async_curation', conversation_id: conv_id)
        end

        def step_response_return; end

        def build_response
          msg = if @raw_response.respond_to?(:content)
                  { role: :assistant, content: @raw_response.content }
                elsif @raw_response.is_a?(Hash) && @raw_response[:content]
                  @raw_response
                else
                  { role: :assistant, content: @raw_response.to_s }
                end

          @timestamps[:returned] = Time.now

          # Use pre-built snapshots when async post-steps are running concurrently
          # to avoid reading partially-mutated timeline/warnings state.
          timeline_events = @_response_timeline_snapshot || @timeline.events
          timeline_parts = @_response_participants_snapshot || @timeline.participants
          warnings_snapshot = @_response_warnings_snapshot || @warnings

          Response.build(
            request_id:      @request.id,
            conversation_id: @request.conversation_id || "conv_#{SecureRandom.hex(8)}",
            message:         msg,
            routing:         build_response_routing,
            tokens:          extract_tokens,
            stop:            extract_stop_reason,
            tools:           response_tool_calls,
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
            quality:         @confidence_score&.to_h
          )
        end

        def requested_deferred_tool_names
          metadata = @request.metadata || {}
          requested = metadata[:requested_tools] || metadata['requested_tools'] || []
          Array(requested).map { |name| name.to_s.tr('.', '_') }.reject(&:empty?)
        end

        def build_response_routing
          routing = { provider: @resolved_provider, model: @resolved_model }

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

        def extract_stop_reason
          reason = if @raw_response.respond_to?(:stop_reason)
                     @raw_response.stop_reason&.to_sym
                   elsif @raw_response.respond_to?(:tool_calls) && @raw_response.tool_calls&.any?
                     :tool_use
                   end
          { reason: reason || :end_turn }
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.pipeline.extract_stop_reason')
          { reason: :end_turn }
        end

        def estimate_response_cost
          tokens = extract_tokens
          input  = tokens.respond_to?(:input_tokens) ? tokens.input_tokens : tokens[:input].to_i
          output = tokens.respond_to?(:output_tokens) ? tokens.output_tokens : tokens[:output].to_i
          return {} unless @resolved_model && (input + output).positive?

          estimated = CostEstimator.estimate(
            model_id:      @resolved_model,
            input_tokens:  input,
            output_tokens: output
          )
          { estimated_usd: estimated, provider: @resolved_provider, model: @resolved_model }
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.pipeline.estimate_response_cost')
          {}
        end

        def response_tool_calls
          return [] unless @raw_response.respond_to?(:tool_calls) && @raw_response.tool_calls

          tool_timeline = build_tool_timeline_index

          Array(@raw_response.tool_calls).map do |tool_call|
            tc_id   = tool_call[:id] || tool_call['id']
            tc_name = tool_call[:name] || tool_call['name']

            entry = {
              id:        tc_id,
              name:      tc_name,
              arguments: tool_call[:arguments] || tool_call['arguments'] || {}
            }

            # Merge execution data from timeline if available
            timeline_data = tool_timeline[tc_name]
            if timeline_data
              entry[:exchange_id] = timeline_data[:exchange_id]
              entry[:source]      = timeline_data[:source]
              entry[:status]      = timeline_data[:status]
              entry[:duration_ms] = timeline_data[:duration_ms]
              entry[:result]      = timeline_data[:result]
            end

            entry
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
