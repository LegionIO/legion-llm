# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Helper
      include Legion::Logging::Helper

      # --- Layered Defaults ---
      # Override in your LEX to set extension-specific defaults.
      # Resolution chain: per-call kwarg -> LEX override -> Settings -> nil (auto-detect)

      def llm_default_model
        return nil unless defined?(Legion::Settings)

        Legion::Settings.dig(:llm, :default_model)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.helper.default_model')
        nil
      end

      def llm_default_provider
        return nil unless defined?(Legion::Settings)

        Legion::Settings.dig(:llm, :default_provider)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.helper.default_provider')
        nil
      end

      def llm_default_intent
        return nil unless defined?(Legion::Settings)

        Legion::Settings.dig(:llm, :routing, :default_intent)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.helper.default_intent')
        nil
      end

      # --- Core Operations ---

      def llm_chat(message, model: nil, provider: nil, intent: nil, tier: nil, tools: [], # rubocop:disable Metrics/ParameterLists
                   instructions: nil, compress: 0, escalate: nil, max_escalations: nil,
                   quality_check: nil, caller: nil, use_default_intent: false)
        effective_model = model || llm_default_model
        effective_provider = provider || llm_default_provider
        effective_intent = intent || (use_default_intent ? llm_default_intent : nil)

        if compress.positive?
          message = Legion::LLM::Context::Compressor.compress(message, level: compress)
          instructions = Legion::LLM::Context::Compressor.compress(instructions, level: compress) if instructions
        end

        if escalate
          return Legion::LLM.chat(model: effective_model, provider: effective_provider,
                                  intent: effective_intent, tier: tier,
                                  escalate: true, max_escalations: max_escalations,
                                  quality_check: quality_check, message: message, caller: caller)
        end

        chat = Legion::LLM.chat(model: effective_model, provider: effective_provider,
                                intent: effective_intent, tier: tier,
                                escalate: false, caller: caller)
        chat.with_instructions(instructions) if instructions
        chat.with_tools(*tools) unless tools.empty?
        chat.ask(message)
      end

      def llm_embed(text, **)
        Legion::LLM.embed(text, **)
      end

      def llm_embed_batch(texts, **)
        Legion::LLM.embed_batch(texts, **)
      end

      def llm_session(model: nil, provider: nil, intent: nil, tier: nil, caller: nil, use_default_intent: false)
        effective_model = model || llm_default_model
        effective_provider = provider || llm_default_provider
        effective_intent = intent || (use_default_intent ? llm_default_intent : nil)

        Legion::LLM.chat(model: effective_model, provider: effective_provider,
                         intent: effective_intent, tier: tier,
                         escalate: false, caller: caller)
      end

      def llm_structured(messages:, schema:, **)
        Legion::LLM.structured(messages: messages, schema: schema, **)
      end

      def llm_ask(message:, **)
        Legion::LLM.ask(message: message, **)
      end

      # --- Status ---

      def llm_connected?
        defined?(Legion::LLM) && Legion::LLM.started?
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.helper.connected')
        false
      end

      def llm_can_embed?
        llm_connected? && Legion::LLM.can_embed?
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.helper.can_embed')
        false
      end

      def llm_routing_enabled?
        llm_connected? && Legion::LLM::Router.routing_enabled?
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.helper.routing_enabled')
        false
      end

      # --- Cost / Budget ---

      def llm_cost_estimate(model: nil, input_tokens: 0, output_tokens: 0)
        model ||= llm_default_model
        Legion::LLM::Metering::Pricing.estimate(model_id: model, input_tokens: input_tokens,
                                              output_tokens: output_tokens)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.helper.cost_estimate', model: model)
        0.0
      end

      def llm_cost_summary(since: nil)
        Legion::LLM::Metering::Recorder.summary(since: since)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.helper.cost_summary')
        { total_cost_usd: 0.0, total_requests: 0, total_input_tokens: 0, total_output_tokens: 0, by_model: {} }
      end

      def llm_budget_remaining
        Legion::LLM::Hooks::BudgetGuard.remaining
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.helper.budget_remaining')
        Float::INFINITY
      end
    end
  end
end
