# frozen_string_literal: true

require 'ruby_llm'
require 'legion/llm/version'
require 'legion/llm/settings'
require 'legion/llm/providers'
require 'legion/llm/router'
require 'legion/llm/compressor'
require 'legion/llm/quality_checker'
require 'legion/llm/escalation_history'
require_relative 'llm/response_cache'
require_relative 'llm/daemon_client'

begin
  require 'legion/extensions/llm/gateway'
rescue LoadError
  nil
end

module Legion
  module LLM
    class EscalationExhausted < StandardError; end
    class DaemonDeniedError < StandardError; end
    class DaemonRateLimitedError < StandardError; end

    class << self
      include Legion::LLM::Providers

      def start
        Legion::Logging.debug 'Legion::LLM is running start'

        require 'legion/llm/claude_config_loader'
        ClaudeConfigLoader.load

        configure_providers
        run_discovery
        set_defaults

        @started = true
        Legion::Settings[:llm][:connected] = true
        Legion::Logging.info 'Legion::LLM started'
        ping_provider
      end

      def shutdown
        Legion::Settings[:llm][:connected] = false
        @started = false
        Legion::Logging.info 'Legion::LLM shut down'
      end

      def started?
        @started == true
      end

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
               max_escalations: nil, quality_check: nil, message: nil, **)
        if defined?(Legion::Telemetry::OpenInference)
          Legion::Telemetry::OpenInference.llm_span(
            model: (model || settings[:default_model]).to_s, provider: provider&.to_s, input: message
          ) do |_span|
            _dispatch_chat(model: model, provider: provider, intent: intent, tier: tier, escalate: escalate, max_escalations: max_escalations,
                           quality_check: quality_check, message: message, **)
          end
        else
          _dispatch_chat(model: model, provider: provider, intent: intent, tier: tier,
                         escalate: escalate, max_escalations: max_escalations,
                         quality_check: quality_check, message: message, **)
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
                      max_escalations: nil, quality_check: nil, message: nil, **)
        escalate = escalation_enabled? if escalate.nil?

        if escalate && message
          chat_with_escalation(
            model: model, provider: provider, intent: intent, tier: tier,
            max_escalations: max_escalations, quality_check: quality_check,
            message: message, **
          )
        else
          chat_single(model: model, provider: provider, intent: intent, tier: tier, **)
        end
      end

      # Generate embeddings — delegates to gateway when available
      def embed(text, **)
        if defined?(Legion::Telemetry::OpenInference)
          Legion::Telemetry::OpenInference.embedding_span(
            model: (settings[:default_model] || 'unknown').to_s
          ) { |_span| _dispatch_embed(text, **) }
        else
          _dispatch_embed(text, **)
        end
      end

      # Direct embed bypassing gateway
      def embed_direct(text, **)
        require 'legion/llm/embeddings'
        Embeddings.generate(text: text, **)
      end

      # Batch embed multiple texts
      # @param texts [Array<String>] texts to embed
      # @return [Array<Hash>]
      def embed_batch(texts, **)
        require 'legion/llm/embeddings'
        Embeddings.generate_batch(texts: texts, **)
      end

      # Generate structured JSON output — delegates to gateway when available
      def structured(messages:, schema:, **)
        if defined?(Legion::Telemetry::OpenInference)
          Legion::Telemetry::OpenInference.llm_span(
            model: (settings[:default_model] || 'unknown').to_s, input: messages.to_s
          ) { |_span| _dispatch_structured(messages: messages, schema: schema, **) }
        else
          _dispatch_structured(messages: messages, schema: schema, **)
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

      private

      def _dispatch_chat(model:, provider:, intent:, tier:, escalate:, max_escalations:, quality_check:, message:, **)
        if gateway_loaded? && message
          return gateway_chat(model: model, provider: provider, intent: intent,
                              tier: tier, message: message, escalate: escalate,
                              max_escalations: max_escalations, quality_check: quality_check, **)
        end

        chat_direct(model: model, provider: provider, intent: intent, tier: tier,
                    escalate: escalate, max_escalations: max_escalations,
                    quality_check: quality_check, message: message, **)
      end

      def _dispatch_embed(text, **)
        return Legion::Extensions::LLM::Gateway::Runners::Inference.embed(text: text, **) if gateway_loaded?

        embed_direct(text, **)
      end

      def _dispatch_structured(messages:, schema:, **)
        if gateway_loaded?
          return Legion::Extensions::LLM::Gateway::Runners::Inference.structured(
            messages: messages, schema: schema, **
          )
        end

        structured_direct(messages: messages, schema: schema, **)
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

      def gateway_loaded?
        defined?(Legion::Extensions::LLM::Gateway::Runners::Inference)
      end

      def gateway_chat(**)
        Legion::Extensions::LLM::Gateway::Runners::Inference.chat(**)
      end

      def chat_single(model:, provider:, intent:, tier:, **kwargs)
        if (intent || tier) && Router.routing_enabled?
          resolution = Router.resolve(intent: intent, tier: tier, model: model, provider: provider)
          if resolution
            resolution = Router::GatewayInterceptor.intercept(resolution, context: kwargs.fetch(:context, {}))
            model    = resolution.model
            provider = resolution.provider
          end
        end

        model    ||= settings[:default_model]
        provider ||= settings[:default_provider]

        opts = {}
        opts[:model]    = model    if model
        opts[:provider] = provider if provider
        opts.merge!(kwargs)

        RubyLLM.chat(**opts)
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
            opts.merge!(kwargs)
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
        return unless defined?(Legion::Transport)

        Legion::Logging.debug("Escalation event: #{final_outcome}, #{history.size} attempts") if Legion.const_defined?('Logging')
      rescue StandardError
        nil
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

      def ping_provider
        model = settings[:default_model]
        provider = settings[:default_provider]
        return unless model && provider

        start_time = Time.now
        RubyLLM.chat(model: model, provider: provider).ask('Respond with only the word: pong')
        elapsed = ((Time.now - start_time) * 1000).round
        Legion::Logging.info "LLM ping #{provider}/#{model}: pong (#{elapsed}ms)"
      rescue StandardError => e
        Legion::Logging.warn "LLM ping failed for #{provider}/#{model}: #{e.message}"
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
