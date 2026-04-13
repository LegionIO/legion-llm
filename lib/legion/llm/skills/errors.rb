# frozen_string_literal: true

require 'legion/llm/errors'

module Legion
  module LLM
    module Skills
      class InvalidSkill < Legion::LLM::LLMError
        def initialize(msg = 'Invalid skill definition')
          super
        end
      end

      class StepError < Legion::LLM::LLMError
        attr_reader :cause

        def initialize(msg, cause: nil)
          super(msg)
          @cause = cause
        end
      end
    end
  end
end
