# frozen_string_literal: true

require_relative 'api/auth'
require_relative 'api/native/helpers'
require_relative 'api/native/inference'
require_relative 'api/native/chat'
require_relative 'api/native/providers'

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      extend Legion::Logging::Helper

      def self.registered(app)
        log.debug('[llm][api] registering all native routes')
        Auth.registered(app)
        Native::Helpers.registered(app)
        Native::Inference.registered(app)
        Native::Chat.registered(app)
        Native::Providers.registered(app)
        log.debug('[llm][api] all native routes registered')
      end

      def self.register_routes
        return unless defined?(Legion::API) && Legion::API.respond_to?(:register_library_routes)

        Legion::API.register_library_routes('llm', self)
        log.debug('[llm][api] routes registered with Legion::API')
      end
    end

    Routes = API
  end
end
