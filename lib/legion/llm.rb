# frozen_string_literal: true

require 'legion/logging/helper'

Object.const_set(:Legion, Module.new) unless Object.const_defined?(:Legion, false)
Legion.const_set(:LLM, Module.new) unless Legion.const_defined?(:LLM, false)

require_relative 'llm/version'
require_relative 'llm/deprecation'
require_relative 'llm/errors'
require_relative 'llm/settings'
require_relative 'llm/caller_identity'
require_relative 'llm/publisher_identity'
require_relative 'llm/call/providers'
require_relative 'llm/call/registry'
require_relative 'llm/call/lex_llm_adapter'
require_relative 'llm/call/dispatch'
require_relative 'llm/call/embeddings'
require_relative 'llm/call/structured_output'
require_relative 'llm/call/daemon_client'
# SSOT v3 routing stack (§6 dependency order): trusted context, immutable
# settings generation, body-hint/header policy, requirement/candidate/rank/
# rejection, then the next_lane facade, session, exact dispatch, and HTTP views.
require 'legion/llm/routing_context'
require 'legion/llm/router/settings_snapshot'
require 'legion/llm/router/settings_state'
require 'legion/llm/router/body_model_hint_policy'
require 'legion/llm/router/header_constraints'
require 'legion/llm/router/input_bound'
require 'legion/llm/router/required_capabilities'
require 'legion/llm/router/request_requirements'
require 'legion/llm/router/candidate_evaluation'
require 'legion/llm/router/candidate_evaluator'
require 'legion/llm/router/ranker'
require 'legion/llm/router/rejection_diagnostics'
require 'legion/llm/router/outcome_classifier'
require_relative 'llm/router'
require 'legion/llm/inference/attempt_context'
require 'legion/llm/inference/routing_session'
require 'legion/llm/call/selection_dispatch'
require 'legion/llm/api/routing_error_mapper'
require 'legion/llm/api/model_catalog'
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
require_relative 'llm/content_hash'
require_relative 'llm/inference'
require_relative 'llm/inference/embed_pipeline'
require_relative 'llm/fleet'
require_relative 'llm/inventory'
require 'legion/llm/inventory/sweeper'
require 'legion/llm/inventory/settings_observer'
require_relative 'llm/metering'
require_relative 'llm/audit'
require_relative 'llm/scheduling'
require_relative 'llm/scheduling/batch'
require_relative 'llm/scheduling/off_peak'
require_relative 'llm/tools/confidence'
require_relative 'llm/tools/special'
require_relative 'llm/tools/dispatcher'
require_relative 'llm/tools/interceptor'
require_relative 'llm/inference/prompt'
require_relative 'llm/helper'
require_relative 'llm/config'
require_relative 'llm/inventory/discovery'
require_relative 'llm/transport'

boot_logger = Object.new.extend(Legion::Logging::Helper)

begin
  require_relative 'llm/skills'
rescue LoadError => e
  boot_logger.handle_exception(e, level: :warn, handled: true, operation: 'llm.boot.require_skills')
end

begin
  require_relative 'llm/api'
rescue LoadError => e
  boot_logger.handle_exception(e, level: :warn, handled: true, operation: 'llm.boot.require_api')
end

require_relative 'llm/compat'

module Legion
  module LLM
    extend Legion::Logging::Helper

    # Top-level legacy class — kept for backwards compat with old raise/rescue sites.
    # New code should use Legion::LLM::Errors::EscalationExhausted (HTTP 503 semantics,
    # requires attempts: and tried_lanes: kwargs). This class is deleted in C6.
    class EscalationExhausted < StandardError; end
    class DaemonDeniedError < StandardError; end
    class DaemonRateLimitedError < StandardError; end
    class PrivacyModeError < StandardError; end

    class << self
      def start
        log.debug '[llm] start.enter'
        Call::Providers.setup
        Inventory::Discovery.run
        Inventory::Discovery.detect_embedding_capability
        Legion::LLM::Inventory::SettingsObserver.attach!
        Config.set_defaults
        Hooks.install_defaults
        Tools::Interceptor.load_defaults

        Legion::LLM::Skills.start if defined?(Legion::LLM::Skills) && Legion::Settings[:llm][:skills][:enabled] != false

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
        Inventory::Discovery.reset!
        Call::Registry.disconnect_all!
        Call::Registry.reset!
        # Clear LLM-level embedding ivars that may have been set via instance_variable_set for testing
        @can_embed = nil
        @embedding_provider = nil
        @embedding_model = nil
        @embedding_instance = nil
        @embedding_fallback_chain = nil
        # Gracefully shut down the async thread pool (curation, reflection, knowledge capture)
        if (pool = Inference::Executor::ASYNC_THREAD_POOL).running?
          pool.shutdown
          pool.wait_for_termination(5)
        end
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
      # rubocop:disable Legion/Framework/NoDirectDispatch -- deprecated shim per CHANGELOG 0.12.16; routes through governed pipeline.
      def chat_direct(...) = Inference.chat_direct(...)
      # rubocop:enable Legion/Framework/NoDirectDispatch

      def embed(text, **)
        if defined?(Legion::Telemetry::OpenInference)
          Legion::Telemetry::OpenInference.embedding_span(
            model: (Legion::Settings[:llm][:default_model] || Legion::Settings[:llm][:telemetry][:unknown_model_tag]).to_s
          ) { |_span| Inference::EmbedPipeline.call(text: text, **) }
        else
          Inference::EmbedPipeline.call(text: text, **)
        end
      end

      # rubocop:disable Legion/Framework/NoDirectDispatch -- deprecated shim per CHANGELOG 0.12.16.
      def embed_direct(text, **)
        Deprecation.warn_once(:embed_direct, replacement: 'Legion::LLM.embed')
        result = Call::Embeddings.generate(text: text, **)
        emit_embed_metering(result)
        result
      end
      # rubocop:enable Legion/Framework/NoDirectDispatch

      def embed_batch(texts, **) = Call::Embeddings.generate_batch(texts: texts, **)

      def structured(messages:, schema:, **)
        if defined?(Legion::Telemetry::OpenInference)
          Legion::Telemetry::OpenInference.llm_span(
            model: (Legion::Settings[:llm][:default_model] || Legion::Settings[:llm][:telemetry][:unknown_model_tag]).to_s, input: messages.to_s
          ) { |_span| Call::StructuredOutput.generate(messages: messages, schema: schema, **) }
        else
          Call::StructuredOutput.generate(messages: messages, schema: schema, **)
        end
      end

      # rubocop:disable Legion/Framework/NoDirectDispatch -- deprecated shim per CHANGELOG 0.12.16.
      def structured_direct(messages:, schema:, **)
        Deprecation.warn_once(:structured_direct, replacement: 'Legion::LLM.structured')
        result = Call::StructuredOutput.generate(messages: messages, schema: schema, **)
        emit_structured_metering(result)
        result
      end
      # rubocop:enable Legion/Framework/NoDirectDispatch

      # These methods check Discovery first, then fall back to instance ivars set directly on LLM
      # (ivar fallback preserves backwards compat for specs that do Legion::LLM.instance_variable_set)
      def can_embed?
        Inventory::Discovery.can_embed? || @can_embed == true
      end

      def embedding_provider
        Inventory::Discovery.embedding_provider || @embedding_provider
      end

      def embedding_model
        Inventory::Discovery.embedding_model || @embedding_model
      end

      def embedding_instance
        Inventory::Discovery.embedding_instance || @embedding_instance
      end

      def embedding_fallback_chain
        Inventory::Discovery.embedding_fallback_chain || @embedding_fallback_chain
      end

      def agent(agent_class, **) = agent_class.new(**)

      private

      def emit_embed_metering(result)
        return unless result.is_a?(Hash) && !result[:error]

        Metering.emit(
          provider:      result[:provider],
          model_id:      result[:model],
          request_type:  'embedding',
          tier:          'direct',
          input_tokens:  result[:tokens].to_i,
          output_tokens: 0,
          total_tokens:  result[:tokens].to_i,
          event_type:    'llm_embedding',
          status:        'success',
          caller:        { requested_by: { type: :system, identity: 'legion:internal:embed_direct' } }
        )
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.embed_direct.metering')
      end

      def emit_structured_metering(result)
        return unless result.is_a?(Hash)

        Metering.emit(
          provider:      result[:provider],
          model_id:      result[:model],
          request_type:  'structured_output',
          tier:          'direct',
          input_tokens:  0,
          output_tokens: 0,
          total_tokens:  0,
          event_type:    'llm_structured',
          status:        result[:valid] ? 'success' : 'error',
          caller:        { requested_by: { type: :system, identity: 'legion:internal:structured_direct' } }
        )
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.structured_direct.metering')
      end
    end
  end
end
