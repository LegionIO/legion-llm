# frozen_string_literal: true

# Backwards-compatibility shim — canonical location is legion/llm/tools/adapter.rb
require_relative '../tools/adapter'

module Legion
  module LLM
    module Pipeline
      ToolAdapter = Tools::Adapter
      McpToolAdapter = Tools::Adapter
    end
  end
end
