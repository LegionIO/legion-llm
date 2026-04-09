# frozen_string_literal: true

# Message classes require Legion::Transport::Message base class at load time.
# Only load when the transport gem is available.
if defined?(Legion::Transport::Message)
  require_relative 'fleet/exchange'
  require_relative 'fleet/request'
  require_relative 'fleet/response'
  require_relative 'fleet/error'
end

require_relative 'fleet/dispatcher'
require_relative 'fleet/handler'
require_relative 'fleet/reply_dispatcher'

module Legion
  module LLM
    module Fleet
    end
  end
end
