# frozen_string_literal: true

module Legion
  module LLM
    module Inference
      module Prompt
      module_function

      # Auto-routed: Router picks the best provider+model based on intent.
      # Primary entry point for most LLM calls.
      # When provider/model are passed explicitly, they take precedence over routing.
      def dispatch(message, # rubocop:disable Metrics/ParameterLists
                   intent: nil,
                   tier: nil,
                   exclude: {},
                   provider: nil,
                   model: nil,
                   schema: nil,
                   tools: nil,
                   escalate: nil,
                   max_escalations: 3,
                   thinking: nil,
                   temperature: nil,
                   max_tokens: nil,
                   tracing: nil,
                   agent: nil,
                   caller: nil,
                   cache: nil,
                   quality_check: nil,
                   **)
        resolved_provider = provider
        resolved_model = model

        if resolved_provider.nil? && resolved_model.nil? && defined?(Router) && Router.routing_enabled? && (intent || tier)
          resolution = Router.resolve(intent: intent, tier: tier, exclude: exclude)
          resolved_provider = resolution&.provider
          resolved_model = resolution&.model
        end

        resolved_provider ||= Legion::LLM.settings[:default_provider]
        resolved_model ||= Legion::LLM.settings[:default_model]

        request(message,
                provider:        resolved_provider,
                model:           resolved_model,
                intent:          intent,
                tier:            tier,
                schema:          schema,
                tools:           tools,
                escalate:        escalate,
                max_escalations: max_escalations,
                thinking:        thinking,
                temperature:     temperature,
                max_tokens:      max_tokens,
                tracing:         tracing,
                agent:           agent,
                caller:          caller,
                cache:           cache,
                quality_check:   quality_check,
                **)
      end

      # Pinned: caller specifies exact provider+model. Full pipeline runs in-process.
      def request(message, # rubocop:disable Metrics/ParameterLists
                  provider:,
                  model:,
                  intent: nil,
                  tier: nil,
                  schema: nil,
                  tools: nil,
                  escalate: nil,
                  max_escalations: 3,
                  thinking: nil,
                  temperature: nil,
                  max_tokens: nil,
                  tracing: nil,
                  agent: nil,
                  caller: nil,
                  cache: nil,
                  quality_check: nil,
                  **)
        if provider.nil? || model.nil?
          raise LLMError, "Prompt.request: provider and model must be set (got provider=#{provider.inspect}, model=#{model.inspect}). " \
                          'Configure Legion::Settings[:llm][:default_provider] and [:default_model], or pass them explicitly.'
        end

        pipeline_request = build_pipeline_request(
          message, provider: provider, model: model, intent: intent, tier: tier,
                   schema: schema, tools: tools,
                   escalate: escalate, max_escalations: max_escalations,
                   thinking: thinking, temperature: temperature, max_tokens: max_tokens,
                   tracing: tracing, agent: agent, caller: caller, cache: cache,
                   quality_check: quality_check, **
        )

        executor = Inference::Executor.new(pipeline_request)
        executor.call
      end

      # Condense a conversation or feedback history into a shorter form.
      def summarize(messages, tools: [], **)
        prompt = build_summarize_prompt(messages)
        dispatch(prompt, tools: tools, **)
      end

      # Extract structured data from unstructured text.
      def extract(text, schema:, tools: [], **)
        prompt = build_extract_prompt(text)
        dispatch(prompt, schema: schema, tools: tools, **)
      end

      # Pick from a set of options with reasoning.
      def decide(question, options:, tools: [], **)
        prompt = build_decide_prompt(question, options)
        dispatch(prompt, tools: tools, **)
      end

      # --- Private helpers ---

      def build_pipeline_request(message, provider:, model:, intent:, tier:, schema:, tools:, # rubocop:disable Metrics/ParameterLists, Metrics/MethodLength
                                 escalate:, max_escalations:, thinking:, temperature:,
                                 max_tokens:, tracing:, agent:, caller:, cache:,
                                 quality_check:, **rest)
        # Build base request via from_chat_args to preserve full pipeline kwargs
        # (context_strategy, tool_choice, idempotency_key, ttl, enrichments, predictions, etc.)
        chat_message = message.is_a?(Array) ? nil : message.to_s
        chat_messages = message.is_a?(Array) ? message : nil

        base = Inference::Request.from_chat_args(
          message:         chat_message,
          messages:        chat_messages,
          model:           model,
          provider:        provider,
          intent:          intent,
          tier:            tier,
          tools:           tools,
          thinking:        thinking,
          tracing:         tracing,
          agent:           agent,
          caller:          caller,
          cache:           cache,
          escalate:        escalate,
          max_escalations: max_escalations,
          quality_check:   quality_check,
          **rest
        )

        # Overlay Prompt-specific translations on top of the base request
        generation = (base.generation || {}).dup
        generation[:temperature] = temperature if temperature

        tokens = (base.tokens || {}).dup
        tokens[:max] = max_tokens if max_tokens

        response_format = if schema
                            { type: :json_schema, schema: schema }
                          elsif base.response_format
                            base.response_format
                          else
                            { type: :text }
                          end

        Inference::Request.build(
          messages:         base.messages,
          system:           base.system,
          routing:          base.routing || { provider: provider, model: model },
          tools:            base.tools || tools || [],
          tool_choice:      base.tool_choice,
          thinking:         base.thinking || thinking,
          generation:       generation,
          tokens:           tokens,
          stop:             base.stop,
          response_format:  response_format,
          stream:           base.stream || false,
          fork:             base.fork,
          cache:            base.cache || cache || { strategy: :default, cacheable: true },
          priority:         base.priority || :normal,
          tracing:          base.tracing || tracing,
          classification:   base.classification,
          caller:           base.caller || caller,
          agent:            base.agent || agent,
          billing:          base.billing,
          test:             base.test,
          modality:         base.modality,
          hooks:            base.hooks,
          conversation_id:  base.conversation_id,
          idempotency_key:  base.idempotency_key,
          schema_version:   base.schema_version,
          id:               base.id,
          ttl:              base.ttl,
          metadata:         base.metadata || {},
          enrichments:      base.enrichments || {},
          predictions:      base.predictions || {},
          context_strategy: base.context_strategy,
          extra:            base.extra || {}
        )
      end

      def build_summarize_prompt(messages)
        text = if messages.is_a?(Array)
                 messages.map { |m| m.is_a?(Hash) ? m[:content] : m.to_s }.join("\n")
               else
                 messages.to_s
               end
        "Summarize the following content concisely, preserving key points:\n\n#{text}"
      end

      def build_extract_prompt(text)
        "Extract structured data from the following text. Return only the JSON matching the provided schema.\n\n#{text}"
      end

      def build_decide_prompt(question, options)
        options_text = options.each_with_index.map { |opt, i| "#{i + 1}. #{opt}" }.join("\n")
        "#{question}\n\nOptions:\n#{options_text}\n\nPick the best option and explain your reasoning."
      end

      private_class_method :build_pipeline_request,
                           :build_summarize_prompt, :build_extract_prompt, :build_decide_prompt
      end
    end
  end
end
