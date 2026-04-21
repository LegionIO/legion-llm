# frozen_string_literal: true

require_relative 'api/auth'
require_relative 'api/native/helpers'
require_relative 'api/native/inference'
require_relative 'api/native/chat'
require_relative 'api/native/providers'
require_relative 'api/translators/openai_request'
require_relative 'api/translators/openai_response'
require_relative 'api/openai/chat_completions'
require_relative 'api/openai/models'
require_relative 'api/openai/embeddings'
require_relative 'api/translators/anthropic_request'
require_relative 'api/translators/anthropic_response'
require_relative 'api/anthropic/messages'

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      extend Legion::Logging::Helper

      def self.registered(app)
        log.debug('[llm][api] registering all routes')
        Auth.registered(app)
        Native::Helpers.registered(app)
        Native::Inference.registered(app)
        Native::Chat.registered(app)
        Native::Providers.registered(app)
        OpenAI::ChatCompletions.registered(app)
        OpenAI::Models.registered(app)
        OpenAI::Embeddings.registered(app)
        Anthropic::Messages.registered(app)
        log.debug('[llm][api] all routes registered')
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
