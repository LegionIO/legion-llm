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
        # @return [RubyLLM::Message] the assistant response
        def llm_chat(message, model: nil, provider: nil, intent: nil, tier: nil, tools: [], instructions: nil)
          chat = Legion::LLM.chat(model: model, provider: provider, intent: intent, tier: tier)
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
        def llm_session(model: nil, provider: nil, intent: nil, tier: nil)
          Legion::LLM.chat(model: model, provider: provider, intent: intent, tier: tier)
        end
      end
    end
  end
end
