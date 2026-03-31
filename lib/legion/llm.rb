# frozen_string_literal: true

require 'ruby_llm'
require 'legion/llm/version'
require 'legion/llm/errors'
require 'legion/llm/conversation_store'
require 'legion/llm/settings'
require 'legion/llm/providers'
require 'legion/llm/router'
require 'legion/llm/compressor'
require 'legion/llm/quality_checker'
require 'legion/llm/confidence_score'
require 'legion/llm/confidence_scorer'
require 'legion/llm/embeddings'
require 'legion/llm/escalation_history'
require 'legion/llm/hooks'
require 'legion/llm/cache'
require 'legion/llm/pipeline'
require 'legion/llm/cost_estimator'
require 'legion/llm/fleet'
require_relative 'llm/response_cache'
require_relative 'llm/daemon_client'
require_relative 'llm/arbitrage'
require_relative 'llm/batch'
require_relative 'llm/scheduling'
require_relative 'llm/off_peak'
require_relative 'llm/cost_tracker'
require_relative 'llm/tool_registry'
require_relative 'llm/override_confidence'
require_relative 'llm/routes'

module Legion
  module LLM
    class EscalationExhausted < StandardError; end
    class DaemonDeniedError < StandardError; end
    class DaemonRateLimitedError < StandardError; end
    class PrivacyModeError < StandardError; end

    class << self
      include Legion::LLM::Providers

      def start
        Legion::Logging.debug 'Legion::LLM is running start'

        require 'legion/llm/claude_config_loader'
        ClaudeConfigLoader.load

        require 'legion/llm/codex_config_loader'
        CodexConfigLoader.load

        resolve_llm_secrets
        configure_providers
        verify_providers
        run_discovery
        detect_embedding_capability
        set_defaults

        install_hooks

        @started = true
        Legion::Settings[:llm][:connected] = true
        Legion::Logging.info 'Legion::LLM started'
        register_routes
      end

      def shutdown
        Legion::Settings[:llm][:connected] = false
        @started = false
        @can_embed = nil
        @embedding_provider = nil
        @embedding_model = nil
        Legion::Logging.info 'Legion::LLM shut down'
      end

      def started?
        @started == true
      end

      def can_embed?
        @can_embed == true
      end

      attr_reader :embedding_provider, :embedding_model

      def settings
        if Legion.const_defined?('Settings')
          Legion::Settings[:llm]
        else
          Legion::LLM::Settings.default
        end
      end

      # Create a new chat session — delegates to lex-llm-gateway when available
      # for automatic metering and fleet dispatch
      def chat(model: nil, provider: nil, intent: nil, tier: nil, escalate: nil,
               max_escalations: nil, quality_check: nil, message: nil, **, &)
        if defined?(Legion::Telemetry::OpenInference)
          Legion::Telemetry::OpenInference.llm_span(
            model: (model || settings[:default_model]).to_s, provider: provider&.to_s, input: message
          ) do |_span|
            _dispatch_chat(model: model, provider: provider, intent: intent, tier: tier, escalate: escalate, max_escalations: max_escalations,
                           quality_check: quality_check, message: message, **, &)
          end
        else
          _dispatch_chat(model: model, provider: provider, intent: intent, tier: tier,
                         escalate: escalate, max_escalations: max_escalations,
                         quality_check: quality_check, message: message, **, &)
        end
      end

      # Send a single message — daemon-first, falls through to direct on unavailability.
      def ask(message:, model: nil, provider: nil, intent: nil, tier: nil,
              context: {}, identity: nil, &)
        if DaemonClient.available?
          result = daemon_ask(message: message, model: model, provider: provider,
                              context: context, tier: tier, identity: identity)
          return result if result
        end

        ask_direct(message: message, model: model, provider: provider,
                   intent: intent, tier: tier, &)
      end

      # Direct chat bypassing gateway — used by gateway runners to avoid recursion
      def chat_direct(model: nil, provider: nil, intent: nil, tier: nil, escalate: nil,
                      max_escalations: nil, quality_check: nil, message: nil, **kwargs)
        cache_opt   = kwargs.delete(:cache) { true }
        temperature = kwargs.delete(:temperature)

        escalate = escalation_enabled? if escalate.nil?
        cache_key = build_cache_key(model, provider, message, temperature) if cacheable?(cache_opt, temperature, message)

        if cache_key
          cached = Cache.get(cache_key)
          if cached
            Legion::Logging.debug 'Legion::LLM cache hit'
            cached_response = cached.dup
            cached_response[:meta] = (cached_response[:meta] || {}).merge(cached: true)
            return cached_response
          end
        end

        urgency = kwargs.delete(:urgency) { :normal }
        deferred = try_defer(intent: intent, urgency: urgency, model: model, provider: provider, message: message, **kwargs)
        return deferred if deferred

        if defined?(Legion::Logging)
          Legion::Logging.debug "[LLM] chat_direct escalate=#{escalate} message_present=#{!message.nil?} model=#{model} provider=#{provider}"
        end
        result = if escalate && message
                   chat_with_escalation(
                     model: model, provider: provider, intent: intent, tier: tier,
                     max_escalations: max_escalations, quality_check: quality_check,
                     message: message, temperature: temperature, **kwargs
                   )
                 else
                   chat_single(model: model, provider: provider, intent: intent, tier: tier,
                               temperature: temperature, message: message, **kwargs)
                 end
        Legion::Logging.debug "[LLM] chat_direct result_class=#{result.class} result_nil=#{result.nil?}" if defined?(Legion::Logging)

        if cache_key && result.is_a?(Hash)
          ttl = settings.dig(:prompt_caching, :response_cache, :ttl_seconds) || Cache::DEFAULT_TTL
          Cache.set(cache_key, result, ttl: ttl)
        end

        result
      end

      # Generate embeddings
      def embed(text, **)
        if defined?(Legion::Telemetry::OpenInference)
          Legion::Telemetry::OpenInference.embedding_span(
            model: (settings[:default_model] || 'unknown').to_s
          ) { |_span| embed_direct(text, **) }
        else
          embed_direct(text, **)
        end
      end

      # Direct embed bypassing gateway
      def embed_direct(text, **)
        Embeddings.generate(text: text, **)
      end

      # Batch embed multiple texts
      # @param texts [Array<String>] texts to embed
      # @return [Array<Hash>]
      def embed_batch(texts, **)
        Embeddings.generate_batch(texts: texts, **)
      end

      # Generate structured JSON output
      def structured(messages:, schema:, **)
        if defined?(Legion::Telemetry::OpenInference)
          Legion::Telemetry::OpenInference.llm_span(
            model: (settings[:default_model] || 'unknown').to_s, input: messages.to_s
          ) { |_span| structured_direct(messages: messages, schema: schema, **) }
        else
          structured_direct(messages: messages, schema: schema, **)
        end
      end

      # Direct structured bypassing gateway
      def structured_direct(messages:, schema:, **)
        require 'legion/llm/structured_output'
        StructuredOutput.generate(messages: messages, schema: schema, **)
      end

      # Create a configured agent instance
      # @param agent_class [Class] a RubyLLM::Agent subclass
      # @param kwargs [Hash] additional options
      # @return [RubyLLM::Agent]
      def agent(agent_class, **)
        agent_class.new(**)
      end

      FRAMEWORK_KEYS = %i[request_id source timestamp datetime task_id parent_id master_id
                          check_subtask generate_task catch_exceptions worker_id principal_id
                          principal_type caller].freeze

      private

      def resolve_llm_secrets
        return unless defined?(Legion::Settings::Resolver)

        Legion::Settings::Resolver.resolve_secrets!(settings)
      rescue StandardError => e
        Legion::Logging.warn "LLM settings resolution failed: #{e.message}" if defined?(Legion::Logging)
      end

      def pipeline_enabled?
        settings[:pipeline_enabled] == true
      rescue StandardError => e
        Legion::Logging.debug("LLM#pipeline_enabled? failed: #{e.message}") if defined?(Legion::Logging)
        false
      end

      def chat_via_pipeline(**, &block)
        request = Pipeline::Request.from_chat_args(**)
        executor = Pipeline::Executor.new(request)
        block ? executor.call_stream(&block) : executor.call
      end

      def _dispatch_chat(model:, provider:, intent:, tier:, escalate:, max_escalations:, quality_check:, message:, **kwargs, &)
        if pipeline_enabled? && (message || kwargs[:messages])
          return chat_via_pipeline(model: model, provider: provider, intent: intent, tier: tier,
                                   message: message, escalate: escalate, max_escalations: max_escalations,
                                   quality_check: quality_check, **kwargs, &)
        end

        if block_given? && message
          return chat_single(model: model, provider: provider, intent: intent, tier: tier,
                             message: message, **kwargs, &)
        end

        messages = message.is_a?(Array) ? message : [{ role: 'user', content: message.to_s }]
        resolved_model = model || settings[:default_model]

        if defined?(Legion::LLM::Hooks)
          blocked = Legion::LLM::Hooks.run_before(messages: messages, model: resolved_model)
          return blocked[:response] if blocked
        end

        result = chat_direct(model: model, provider: provider, intent: intent, tier: tier,
                             escalate: escalate, max_escalations: max_escalations,
                             quality_check: quality_check, message: message, **kwargs)

        if defined?(Legion::LLM::Hooks)
          blocked = Legion::LLM::Hooks.run_after(response: result, messages: messages, model: resolved_model)
          return blocked[:response] if blocked
        end

        result = apply_response_guards(result, kwargs) if response_guards_enabled? && result.is_a?(Hash)

        result
      end

      def daemon_ask(message:, model: nil, provider: nil, context: {}, tier: nil, identity: nil) # rubocop:disable Lint/UnusedMethodArgument
        result = DaemonClient.chat(
          message: message, model: model, provider: provider,
          context: context, tier_preference: tier || :auto
        )

        case result[:status]
        when :immediate, :created
          result[:body]
        when :accepted
          ResponseCache.poll(result[:request_id])
        when :denied
          raise DaemonDeniedError, result.dig(:error, :message) || 'Access denied'
        when :rate_limited
          raise DaemonRateLimitedError, "Rate limited. Retry after #{result[:retry_after]}s"
        end
        # Returns nil for :unavailable/:error — caller falls through to direct
      end

      def ask_direct(message:, model: nil, provider: nil, intent: nil, tier: nil, &block)
        assert_cloud_allowed! if effective_tier_is_cloud?(tier, provider)
        session = chat_direct(model: model, provider: provider, intent: intent, tier: tier)
        response = block ? session.ask(message, &block) : session.ask(message)

        {
          status:   :done,
          response: response.content,
          meta:     {
            tier:       :direct,
            model:      session.model.to_s,
            tokens_in:  response.respond_to?(:input_tokens) ? response.input_tokens : nil,
            tokens_out: response.respond_to?(:output_tokens) ? response.output_tokens : nil
          }
        }
      end

      def chat_single(model:, provider:, intent:, tier:, message: nil, **kwargs, &block) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        explicit_tools = kwargs.delete(:tools)
        tools = explicit_tools || ToolRegistry.tools
        tools = nil if tools.empty?

        if (intent || tier) && Router.routing_enabled?
          resolution = Router.resolve(intent: intent, tier: tier, model: model, provider: provider)
          if resolution
            resolution = Router::GatewayInterceptor.intercept(resolution, context: kwargs.fetch(:context, {}))
            model    = resolution.model
            provider = resolution.provider
            assert_cloud_allowed! if resolution.tier.to_sym == :cloud
          end
        elsif tier
          assert_cloud_allowed! if tier.to_sym == :cloud
        end

        model    ||= settings[:default_model]
        provider ||= settings[:default_provider]

        opts = {}
        opts[:model]    = model    if model
        opts[:provider] = provider if provider
        opts.merge!(kwargs.except(*FRAMEWORK_KEYS))
        opts.delete(:temperature) if opts[:temperature].nil?

        inject_anthropic_cache_control!(opts, provider)

        if defined?(Legion::Logging)
          Legion::Logging.debug "[LLM] chat_single model=#{opts[:model]} provider=#{opts[:provider]} message_present=#{!message.nil?} tools=#{tools&.size || 0}"
        end
        session = RubyLLM.chat(**opts)
        tools&.each { |tool| session.with_tool(tool) }
        return session unless message

        Legion::Logging.debug '[LLM] chat_single calling session.ask' if defined?(Legion::Logging)
        response = block ? session.ask(message, &block) : session.ask(message)
        Legion::Logging.debug "[LLM] chat_single response_class=#{response.class} response_nil=#{response.nil?}" if defined?(Legion::Logging)

        if response && !block && ShadowEval.enabled?
          msgs = session.respond_to?(:messages) ? session.messages : nil
          maybe_shadow_evaluate(response, msgs, opts[:model])
        end

        response
      end

      def try_defer(intent:, urgency:, model:, provider:, message:, **)
        return nil unless Scheduling.enabled? && Scheduling.should_defer?(intent: intent || :normal, urgency: urgency)
        return nil unless defined?(Batch) && Batch.enabled?

        entry_id = Batch.enqueue(model: model, provider: provider, message: message, priority: urgency, **)
        { deferred: true, batch_id: entry_id, next_off_peak: Scheduling.next_off_peak.iso8601 }
      end

      def maybe_shadow_evaluate(response, messages, primary_model)
        return unless ShadowEval.enabled? && ShadowEval.should_sample?

        Thread.new do
          ShadowEval.evaluate(
            primary_response: { content: response.respond_to?(:content) ? response.content : response.to_s,
                                model: primary_model, usage: {} },
            messages:         messages
          )
        rescue StandardError => e
          Legion::Logging.debug("shadow evaluation failed: #{e.message}") if defined?(Legion::Logging)
        end
      end

      def chat_with_escalation(model:, provider:, intent:, tier:, max_escalations:, quality_check:, message:, **kwargs)
        chain = Router.resolve_chain(
          intent: intent, tier: tier, model: model, provider: provider,
          max_escalations: max_escalations
        )

        threshold = escalation_quality_threshold
        history = []

        chain.each do |resolution|
          start_time = Time.now
          begin
            opts = { model: resolution.model, provider: resolution.provider }
            opts.merge!(kwargs.except(*FRAMEWORK_KEYS))
            chat_obj = RubyLLM.chat(**opts)
            response = chat_obj.ask(message)

            duration_ms = ((Time.now - start_time) * 1000).round
            result = QualityChecker.check(response, quality_threshold: threshold, quality_check: quality_check)

            if result.passed
              report_health(:success, resolution, duration_ms)
              history << build_attempt(resolution, :success, [], duration_ms)
              attach_escalation_history(response, history, resolution, chain)
              publish_escalation_event(history, :success) if history.size > 1
              return response
            else
              report_health(:quality_failure, resolution, duration_ms, failures: result.failures)
              history << build_attempt(resolution, :quality_failure, result.failures, duration_ms)
            end
          rescue StandardError => e
            duration_ms = ((Time.now - start_time) * 1000).round
            Legion::Logging.warn("Escalation attempt failed model=#{resolution.model}: #{e.message}") if defined?(Legion::Logging)
            report_health(:error, resolution, duration_ms)
            history << build_attempt(resolution, :error, [e.class.name], duration_ms)
          end
        end

        publish_escalation_event(history, :exhausted) if history.size > 1
        raise EscalationExhausted, "All #{history.size} escalation attempts failed"
      end

      def build_attempt(resolution, outcome, failures, duration_ms)
        { model: resolution.model, provider: resolution.provider, tier: resolution.tier,
          outcome: outcome, failures: failures, duration_ms: duration_ms }
      end

      def attach_escalation_history(response, history, resolution, chain)
        return unless response.respond_to?(:extend)

        response.extend(EscalationHistory)
        history.each { |h| response.record_escalation_attempt(**h) }
        response.final_resolution = resolution
        response.escalation_chain = chain
      end

      def report_health(signal, resolution, duration_ms, failures: nil)
        return unless Router.routing_enabled?

        metadata = { duration_ms: duration_ms }
        metadata[:failures] = failures if failures
        Router.health_tracker.report(provider: resolution.provider, signal: signal, value: 1, metadata: metadata)
        Router.health_tracker.report(provider: resolution.provider, signal: :latency, value: duration_ms, metadata: {})
      end

      def publish_escalation_event(history, final_outcome)
        payload = {
          outcome:   final_outcome,
          attempts:  history.size,
          history:   history,
          timestamp: Time.now.utc.iso8601
        }

        Legion::Events.emit('llm.escalation', **payload) if defined?(Legion::Events) && Legion::Events.respond_to?(:emit)

        Legion::Logging.info("Escalation event: #{final_outcome}, #{history.size} attempts") if defined?(Legion::Logging)

        if defined?(Legion::Transport) && Legion::Transport.respond_to?(:connected?) && Legion::Transport.connected?
          Transport::Messages::EscalationEvent.new(payload).publish
        end
      rescue StandardError => e
        Legion::Logging.warn("publish_escalation_event failed: #{e.message}") if defined?(Legion::Logging)
        nil
      end

      def response_guards_enabled?
        settings.dig(:response_guards, :enabled) == true
      end

      def apply_response_guards(result, kwargs)
        context = kwargs[:context]
        response_text = result[:response] || result[:content]
        guard_result = Hooks::ResponseGuard.guard_response(
          response: response_text, context: context
        )

        Legion::Logging.warn "Response guard failed: #{guard_result.inspect}" if !guard_result[:passed] && Legion.const_defined?('Logging')

        result.merge(_guard_result: guard_result)
      rescue StandardError => e
        Legion::Logging.warn("apply_response_guards failed: #{e.message}") if defined?(Legion::Logging)
        result
      end

      def cacheable?(cache_opt, temperature, message)
        cache_opt != false && temperature.to_f.zero? && message && Cache.enabled?
      end

      def build_cache_key(model, provider, message, temperature)
        messages_arr = message.is_a?(Array) ? message : [{ role: 'user', content: message.to_s }]
        Cache.key(
          model:       model || settings[:default_model],
          provider:    provider || settings[:default_provider],
          messages:    messages_arr,
          temperature: temperature
        )
      end

      def inject_anthropic_cache_control!(opts, provider)
        resolved_provider = (provider || settings[:default_provider])&.to_sym
        return unless resolved_provider == :anthropic

        caching_settings = settings[:prompt_caching] || {}
        return unless caching_settings[:enabled] != false

        min_tokens = caching_settings[:min_tokens] || 1024
        instructions = opts[:instructions]
        return unless instructions.is_a?(String) && instructions.length > min_tokens

        opts[:instructions] = {
          content:       instructions,
          cache_control: { type: 'ephemeral' }
        }
      end

      def escalation_enabled?
        routing = settings[:routing]
        return false unless routing.is_a?(Hash)

        esc = routing[:escalation] || {}
        esc[:enabled] == true
      end

      def escalation_quality_threshold
        routing = settings[:routing]
        return 50 unless routing.is_a?(Hash)

        esc = routing[:escalation] || {}
        esc.fetch(:quality_threshold, 50)
      end

      def enterprise_privacy?
        if Legion.const_defined?('Settings') && Legion::Settings.respond_to?(:enterprise_privacy?)
          Legion::Settings.enterprise_privacy?
        else
          ENV['LEGION_ENTERPRISE_PRIVACY'] == 'true'
        end
      end

      def assert_cloud_allowed!
        return unless enterprise_privacy?

        raise PrivacyModeError,
              'Cloud LLM tier is disabled: enterprise_data_privacy is enabled. ' \
              'Only Tier 0 (cache) and Tier 1 (local Ollama) are permitted.'
      end

      def effective_tier_is_cloud?(tier, provider)
        return tier.to_sym == :cloud if tier
        return false unless enterprise_privacy?

        resolved = provider || settings[:default_provider]
        cloud_providers = %i[anthropic bedrock openai gemini azure]
        cloud_providers.include?(resolved&.to_sym)
      end

      def install_hooks
        metering_enabled = settings.dig(:metering, :auto) != false
        Hooks::Metering.install if metering_enabled

        cost_tracking_enabled = settings.dig(:cost_tracking, :auto) != false
        Hooks::CostTracking.install if cost_tracking_enabled

        Hooks::BudgetGuard.install if Hooks::BudgetGuard.enforcing?
      rescue StandardError => e
        Legion::Logging.debug("LLM hook installation failed: #{e.message}") if defined?(Legion::Logging)
      end

      def set_defaults
        default_model    = settings[:default_model]
        default_provider = settings[:default_provider]

        RubyLLM.configure do |c|
          c.default_model = default_model if default_model
        end

        return unless default_model.nil? && default_provider.nil?

        # Auto-detect: use first enabled provider's sensible default
        auto_configure_defaults
      end

      def detect_embedding_capability
        embedding_settings = settings[:embedding] || {}
        found = find_embedding_provider(embedding_settings)
        if found
          @can_embed = true
          @embedding_provider = found[:provider]
          @embedding_model = found[:model]
          Legion::Logging.info "Embedding available: #{@embedding_provider}:#{@embedding_model}"
        else
          @can_embed = false
          Legion::Logging.info 'No embedding provider available'
        end
      rescue StandardError => e
        @can_embed = false
        Legion::Logging.warn "Embedding detection failed: #{e.message}" if defined?(Legion::Logging)
      end

      def find_embedding_provider(embedding_settings)
        fallback = embedding_settings[:provider_fallback] || %w[ollama bedrock openai]
        provider_models = embedding_settings[:provider_models] || {}
        ollama_preferred = embedding_settings[:ollama_preferred] || %w[mxbai-embed-large bge-large snowflake-arctic-embed]

        fallback.each do |provider_name|
          provider = provider_name.to_sym
          model = provider_models[provider_name] || provider_models[provider]
          available = probe_embedding_provider(provider, ollama_preferred)
          next unless available

          resolved_model = available.is_a?(String) ? available : model&.to_s
          next unless verify_embedding(provider, resolved_model)

          return { provider: provider, model: resolved_model }
        end
        nil
      end

      def verify_embedding(provider, model)
        return true if provider == :ollama
        return true unless model

        start_time = Time.now
        RubyLLM.embed('health check', model: model, provider: provider)
        elapsed = ((Time.now - start_time) * 1000).round
        Legion::Logging.info "Embedding health check #{provider}/#{model}: OK (#{elapsed}ms)"
        true
      rescue RubyLLM::ModelNotFoundError => e
        Legion::Logging.warn "Embedding health check #{provider}/#{model}: model not in RubyLLM registry (#{e.message}) — skipping"
        false
      rescue StandardError => e
        Legion::Logging.warn "Embedding health check failed for #{provider}/#{model}: #{e.class}: #{e.message} — skipping"
        false
      end

      def probe_embedding_provider(provider, ollama_preferred)
        case provider
        when :ollama then detect_ollama_embedding(ollama_preferred)
        else              detect_cloud_embedding(provider)
        end
      end

      def detect_ollama_embedding(preferred_models)
        return nil unless defined?(Legion::LLM::Discovery::Ollama)
        return nil unless settings.dig(:providers, :ollama, :enabled)

        preferred_models.each do |model|
          return model if Legion::LLM::Discovery::Ollama.model_available?(model)
        end
        nil
      rescue StandardError
        nil
      end

      def detect_cloud_embedding(provider)
        provider_config = settings.dig(:providers, provider)
        return nil unless provider_config.is_a?(Hash) && provider_config[:enabled]

        true
      rescue StandardError
        nil
      end

      def run_discovery
        return unless settings.dig(:providers, :ollama, :enabled)

        Discovery::Ollama.refresh!
        Discovery::System.refresh!

        names = Discovery::Ollama.model_names
        count = names.size
        Legion::Logging.info "Ollama: #{count} model#{'s' unless count == 1} available (#{names.join(', ')})"
        Legion::Logging.info "System: #{Discovery::System.total_memory_mb} MB total, " \
                             "#{Discovery::System.available_memory_mb} MB available"
      rescue StandardError => e
        Legion::Logging.warn "Discovery failed: #{e.message}"
      end

      def register_routes
        return unless defined?(Legion::API) && Legion::API.respond_to?(:register_library_routes)

        Legion::API.register_library_routes('llm', Legion::LLM::Routes)
        Legion::Logging.debug 'Legion::LLM routes registered with API'
      rescue StandardError => e
        Legion::Logging.warn "Legion::LLM route registration failed: #{e.message}" if defined?(Legion::Logging)
      end

      def auto_configure_defaults
        settings[:providers].each do |provider, config|
          next unless config&.dig(:enabled)

          model = config[:default_model]
          next unless model

          settings[:default_model]    = model
          settings[:default_provider] = provider
          Legion::Logging.info "Auto-configured default: #{model} via #{provider}"
          break
        end
      end
    end
  end
end
