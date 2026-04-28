# frozen_string_literal: true

module Legion
  module LLM
    module Inference
      if Legion::LLM.ruby_llm_available?
        # Backwards-compatibility shim — canonical location is legion/llm/tools/adapter.rb
        require_relative '../tools/adapter'
        ToolAdapter = Tools::Adapter
        McpToolAdapter = Tools::Adapter
      else
        class ToolAdapter
          def initialize(*)
            raise Legion::LLM::ProviderError, 'RubyLLM tool adapters are unavailable because ruby_llm is not installed'
          end
        end

        McpToolAdapter = ToolAdapter
      end
    end
  end
end
