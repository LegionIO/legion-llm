# frozen_string_literal: true

require 'legion/extensions/llm/fleet/worker_execution'

module Legion
  module LLM
    module Fleet
      WorkerExecution = ::Legion::Extensions::Llm::Fleet::WorkerExecution unless const_defined?(:WorkerExecution, false)
    end
  end
end
