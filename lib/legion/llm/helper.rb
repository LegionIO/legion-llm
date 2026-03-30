# frozen_string_literal: true

module Legion
  module LLM
    module Helper
      # --- Layered Defaults ---
      # Override in your LEX to set extension-specific defaults.
      # Resolution chain: per-call kwarg -> LEX override -> Settings -> nil (auto-detect)

      def llm_default_model
        return nil unless defined?(Legion::Settings)

        Legion::Settings.dig(:llm, :default_model)
      rescue StandardError
        nil
      end

      def llm_default_provider
        return nil unless defined?(Legion::Settings)

        Legion::Settings.dig(:llm, :default_provider)
      rescue StandardError
        nil
      end

      def llm_default_intent
        return nil unless defined?(Legion::Settings)

        Legion::Settings.dig(:llm, :routing, :default_intent)
      rescue StandardError
        nil
      end

      # --- Core Operations ---

      def llm_chat(message, model: nil, provider: nil, intent: nil, tier: nil, tools: [], # rubocop:disable Metrics/ParameterLists
                   instructions: nil, compress: 0, escalate: nil, max_escalations: nil,
                   quality_check: nil, caller: nil)
        effective_model = model || llm_default_model
        effective_provider = provider || llm_default_provider
        effective_intent = intent || llm_default_intent

        if compress.positive?
          message = Legion::LLM::Compressor.compress(message, level: compress)
          instructions = Legion::LLM::Compressor.compress(instructions, level: compress) if instructions
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

      def llm_session(model: nil, provider: nil, intent: nil, tier: nil, caller: nil)
        effective_model = model || llm_default_model
        effective_provider = provider || llm_default_provider
        effective_intent = intent || llm_default_intent

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
      rescue StandardError
        false
      end

      def llm_can_embed?
        llm_connected? && Legion::LLM.can_embed?
      rescue StandardError
        false
      end

      def llm_routing_enabled?
        llm_connected? && Legion::LLM::Router.routing_enabled?
      rescue StandardError
        false
      end

      # --- Cost / Budget ---

      def llm_cost_estimate(model:, input_tokens: 0, output_tokens: 0)
        Legion::LLM::CostEstimator.estimate(model_id: model, input_tokens: input_tokens,
                                            output_tokens: output_tokens)
      rescue StandardError
        0.0
      end

      def llm_cost_summary(since: nil)
        Legion::LLM::CostTracker.summary(since: since)
      rescue StandardError
        { total_cost_usd: 0.0, total_requests: 0, total_input_tokens: 0, total_output_tokens: 0, by_model: {} }
      end

      def llm_budget_remaining
        Legion::LLM::Hooks::BudgetGuard.remaining
      rescue StandardError
        Float::INFINITY
      end
    end
  end
end
