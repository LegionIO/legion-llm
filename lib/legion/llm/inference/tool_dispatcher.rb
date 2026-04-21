# frozen_string_literal: true

# Backwards-compatibility shim — canonical location is legion/llm/tools/dispatcher.rb
require_relative '../tools/dispatcher'

module Legion
  module LLM
    module Pipeline
      ToolDispatcher = Tools::Dispatcher
    end
  end
end
