# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'

module Legion
  module LLM
    module Fleet
      ProviderResponder = ::Legion::Extensions::Llm::Fleet::ProviderResponder unless const_defined?(:ProviderResponder,
                                                                                                    false)
    end
  end
end
