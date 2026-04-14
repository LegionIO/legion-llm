# frozen_string_literal: true

module Legion
  module LLM
    module Prompt
      module_function

      # Auto-routed: Router picks the best provider+model based on intent.
      # Primary entry point for most LLM calls.
      # When provider/model are passed explicitly, they take precedence over routing.
      def dispatch(message, # rubocop:disable Metrics/ParameterLists
                   intent: nil,
                   exclude: {}, # rubocop:disable Lint/UnusedMethodArgument -- consumed by Router in WS-00E
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

        if resolved_provider.nil? && resolved_model.nil? && intent && defined?(Router) && Router.routing_enabled?
          resolution = Router.resolve(intent: intent)
          resolved_provider = resolution&.provider
          resolved_model = resolution&.model
        end

        resolved_provider ||= Legion::LLM.settings[:default_provider]
        resolved_model ||= Legion::LLM.settings[:default_model]

        request(message,
                provider:        resolved_provider,
                model:           resolved_model,
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
          message, provider: provider, model: model, schema: schema, tools: tools,
                   escalate: escalate, max_escalations: max_escalations,
                   thinking: thinking, temperature: temperature, max_tokens: max_tokens,
                   tracing: tracing, agent: agent, caller: caller, cache: cache,
                   quality_check: quality_check, **
        )

        executor = Pipeline::Executor.new(pipeline_request)
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

      def build_pipeline_request(message, provider:, model:, schema:, tools:, # rubocop:disable Metrics/ParameterLists
                                 escalate:, max_escalations:, thinking:, temperature:,
                                 max_tokens:, tracing:, agent:, caller:, cache:,
                                 quality_check:, **rest)
        messages = message.is_a?(Array) ? message : [{ role: :user, content: message.to_s }]

        generation = {}
        generation[:temperature] = temperature if temperature

        tokens = { max: max_tokens || 4096 }

        response_format = if schema
                            { type: :json_schema, schema: schema }
                          else
                            { type: :text }
                          end

        extra = { quality_check: quality_check, escalate: escalate, max_escalations: max_escalations }
        extra.merge!(rest.except(:system, :messages, :conversation_id, :priority, :metadata, :stream))

        Pipeline::Request.build(
          messages:        messages,
          system:          rest[:system],
          routing:         { provider: provider, model: model },
          tools:           tools || [],
          thinking:        thinking,
          generation:      generation,
          tokens:          tokens,
          response_format: response_format,
          tracing:         tracing,
          agent:           agent,
          caller:          caller,
          cache:           cache || { strategy: :default, cacheable: true },
          conversation_id: rest[:conversation_id],
          priority:        rest[:priority] || :normal,
          metadata:        rest[:metadata] || {},
          stream:          rest[:stream] || false,
          extra:           extra
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
