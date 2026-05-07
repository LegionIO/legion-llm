# frozen_string_literal: true

require 'legion/extensions/llm/fleet/token_error'
require 'legion/extensions/llm/fleet/token_validator'

module Legion
  module LLM
    module Fleet
      TokenError = ::Legion::Extensions::Llm::Fleet::TokenError unless const_defined?(:TokenError, false)
      TokenValidator = ::Legion::Extensions::Llm::Fleet::TokenValidator unless const_defined?(:TokenValidator, false)
    end
  end
end
