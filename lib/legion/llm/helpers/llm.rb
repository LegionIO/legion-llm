# frozen_string_literal: true

module Legion
  module Extensions
    module Helpers
      module LLM
        # Quick chat from any extension runner
        # @param message [String] the prompt
        # @param model [String] optional model override
        # @param provider [Symbol] optional provider override
        # @param intent [Hash, nil] routing intent (capability, privacy, etc.)
        # @param tier [Symbol, nil] explicit tier override
        # @param tools [Array<Class>] optional RubyLLM::Tool subclasses
        # @param instructions [String] optional system instructions
        # @param escalate [Boolean, nil] enable model escalation on low-quality responses
        # @param max_escalations [Integer, nil] max escalation attempts
        # @param quality_check [Proc, nil] callable that returns true if response is acceptable
        # @return [RubyLLM::Message] the assistant response
        def llm_chat(message, model: nil, provider: nil, intent: nil, tier: nil, tools: [], instructions: nil, # rubocop:disable Metrics/ParameterLists
                     compress: 0, escalate: nil, max_escalations: nil, quality_check: nil, caller: nil)
          if compress.positive?
            message = Legion::LLM::Compressor.compress(message, level: compress)
            instructions = Legion::LLM::Compressor.compress(instructions, level: compress) if instructions
          end

          # When escalation is active, chat() handles ask() internally via message: kwarg
          if escalate
            return Legion::LLM.chat(model: model, provider: provider, intent: intent, tier: tier,
                                    escalate: true, max_escalations: max_escalations,
                                    quality_check: quality_check, message: message, caller: caller)
          end

          chat = Legion::LLM.chat(model: model, provider: provider, intent: intent, tier: tier,
                                  escalate: false, caller: caller)
          chat.with_instructions(instructions) if instructions
          chat.with_tools(*tools) unless tools.empty?
          chat.ask(message)
        end

        # Quick embed from any extension runner
        # @param text [String, Array<String>] text to embed
        # @param model [String] optional model override
        # @return [RubyLLM::Embedding]
        def llm_embed(text, model: nil)
          Legion::LLM.embed(text, model: model)
        end

        # Get a raw chat object for multi-turn conversations
        # @param model [String] optional model override
        # @param provider [Symbol] optional provider override
        # @param intent [Hash, nil] routing intent (capability, privacy, etc.)
        # @param tier [Symbol, nil] explicit tier override
        # @return [RubyLLM::Chat]
        def llm_session(model: nil, provider: nil, intent: nil, tier: nil, caller: nil)
          Legion::LLM.chat(model: model, provider: provider, intent: intent, tier: tier, escalate: false, caller: caller)
        end
      end
    end
  end
end
