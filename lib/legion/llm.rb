# frozen_string_literal: true

require 'legion/logging/helper'

require 'ruby_llm'
require_relative 'llm/patches/ruby_llm_parallel_tools'
require_relative 'llm/patches/ruby_llm_vllm'
require_relative 'llm/version'
require_relative 'llm/errors'
require_relative 'llm/settings'
require_relative 'llm/call/providers'
require_relative 'llm/call/registry'
require_relative 'llm/call/dispatch'
require_relative 'llm/call/embeddings'
require_relative 'llm/call/structured_output'
require_relative 'llm/call/daemon_client'
require_relative 'llm/call/bedrock_auth'
require_relative 'llm/call/claude_config_loader'
require_relative 'llm/call/codex_config_loader'
require_relative 'llm/router'
require_relative 'llm/context/compressor'
require_relative 'llm/context/curator'
require_relative 'llm/metering/usage'
require_relative 'llm/metering/estimator'
require_relative 'llm/metering/tracker'
require_relative 'llm/metering/tokens'
require_relative 'llm/quality/checker'
require_relative 'llm/quality/confidence/score'
require_relative 'llm/quality/confidence/scorer'
require_relative 'llm/quality/shadow_eval'
require_relative 'llm/types'
require_relative 'llm/inference/conversation'
require_relative 'llm/router/escalation/history'
require_relative 'llm/hooks'
require_relative 'llm/cache'
require_relative 'llm/cache/response'
require_relative 'llm/inference'
require_relative 'llm/fleet'
require_relative 'llm/metering'
require_relative 'llm/audit'
require_relative 'llm/scheduling'
require_relative 'llm/scheduling/batch'
require_relative 'llm/scheduling/off_peak'
require_relative 'llm/tools/confidence'
require_relative 'llm/tools/dispatcher'
require_relative 'llm/tools/interceptor'
require_relative 'llm/tools/adapter'
require_relative 'llm/inference/prompt'
require_relative 'llm/helper'
require_relative 'llm/config'
require_relative 'llm/discovery'
require_relative 'llm/transport'

begin
  require_relative 'llm/skills'
rescue LoadError => e
  Legion::Logging.debug "LLM: skills not loadable: #{e.message}"
end

begin
  require_relative 'llm/api'
rescue LoadError => e
  Legion::Logging.debug "LLM: api routes not loadable (Sinatra not available): #{e.message}"
end

require_relative 'llm/compat'

module Legion
  module LLM
    extend Legion::Logging::Helper

    class EscalationExhausted < StandardError; end
    class DaemonDeniedError < StandardError; end
    class DaemonRateLimitedError < StandardError; end
    class PrivacyModeError < StandardError; end

    class << self
      def start
        log.debug '[llm] start.enter'
        Call::ClaudeConfigLoader.load
        Call::CodexConfigLoader.load
        Call::Providers.setup
        Discovery.run
        Discovery.detect_embedding_capability
        Config.set_defaults
        Hooks.install_defaults
        Tools::Interceptor.load_defaults

        Legion::LLM::Skills.start if defined?(Legion::LLM::Skills) && settings.dig(:skills, :enabled) != false

        LLM::Transport.load_all
        LLM::Fleet.load_transport
        LLM::Audit.load_transport
        LLM::Metering.load_transport

        @started = true
        Legion::Settings[:llm][:connected] = true
        log.info '[llm] started'
        API.register_routes if defined?(API)
      rescue StandardError => e
        handle_exception(e, level: :error, operation: 'llm.start')
        raise
      end

      def shutdown
        log.debug '[llm] shutdown.enter'
        Legion::Settings[:llm][:connected] = false
        @started = false
        Discovery.reset!
        Call::Registry.reset!
        # Clear LLM-level embedding ivars that may have been set via instance_variable_set for testing
        @can_embed = nil
        @embedding_provider = nil
        @embedding_model = nil
        @embedding_fallback_chain = nil
        log.info '[llm] shut down'
      end

      def started?
        @started == true
      end

      def settings
        Legion::Settings[:llm]
      end

      def chat(...) = Inference.chat(...)
      def ask(...) = Inference.ask(...)
      def chat_direct(...) = Inference.chat_direct(...)

      def embed(text, **)
        if defined?(Legion::Telemetry::OpenInference)
          Legion::Telemetry::OpenInference.embedding_span(
            model: (settings[:default_model] || 'unknown').to_s
          ) { |_span| Call::Embeddings.generate(text: text, **) }
        else
          Call::Embeddings.generate(text: text, **)
        end
      end

      def embed_direct(text, **) = Call::Embeddings.generate(text: text, **)
      def embed_batch(texts, **) = Call::Embeddings.generate_batch(texts: texts, **)

      def structured(messages:, schema:, **)
        if defined?(Legion::Telemetry::OpenInference)
          Legion::Telemetry::OpenInference.llm_span(
            model: (settings[:default_model] || 'unknown').to_s, input: messages.to_s
          ) { |_span| Call::StructuredOutput.generate(messages: messages, schema: schema, **) }
        else
          Call::StructuredOutput.generate(messages: messages, schema: schema, **)
        end
      end

      def structured_direct(messages:, schema:, **) = Call::StructuredOutput.generate(messages: messages, schema: schema, **)

      # These methods check Discovery first, then fall back to instance ivars set directly on LLM
      # (ivar fallback preserves backwards compat for specs that do Legion::LLM.instance_variable_set)
      def can_embed?
        Discovery.can_embed? || @can_embed == true
      end

      def embedding_provider
        Discovery.embedding_provider || @embedding_provider
      end

      def embedding_model
        Discovery.embedding_model || @embedding_model
      end

      def embedding_fallback_chain
        Discovery.embedding_fallback_chain || @embedding_fallback_chain
      end

      def agent(agent_class, **) = agent_class.new(**)
    end
  end
end
