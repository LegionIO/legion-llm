# frozen_string_literal: true

module Legion
  module Extensions
    module Helpers
      module LLM
        # Quick chat from any extension runner
        # @param message [String] the prompt
        # @param model [String] optional model override
        # @param provider [Symbol] optional provider override
        # @param tools [Array<Class>] optional RubyLLM::Tool subclasses
        # @param instructions [String] optional system instructions
        # @return [RubyLLM::Message] the assistant response
        def llm_chat(message, model: nil, provider: nil, tools: [], instructions: nil)
          chat = Legion::LLM.chat(model: model, provider: provider)
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
        # @return [RubyLLM::Chat]
        def llm_session(model: nil, provider: nil)
          Legion::LLM.chat(model: model, provider: provider)
        end
      end
    end
  end
end
