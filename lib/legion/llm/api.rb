# frozen_string_literal: true

require_relative 'api/auth'
require_relative 'api/native/helpers'
require_relative 'api/native/inference'
require_relative 'api/native/chat'
require_relative 'api/native/providers'
require_relative 'api/native/models'
require_relative 'api/native/offerings'
require_relative 'api/native/instances'
require_relative 'api/native/routing'
require_relative 'api/native/tiers'
require_relative 'api/translators/openai_request'
require_relative 'api/translators/openai_response'
require_relative 'api/openai/chat_completions'
require_relative 'api/openai/models'
require_relative 'api/openai/embeddings'
require_relative 'api/openai/responses'
require_relative 'api/translators/anthropic_request'
require_relative 'api/translators/anthropic_response'
require_relative 'api/anthropic/messages'
require_relative 'api/namespaces/registration'
require 'legion/llm/api/inventory_admin'

require 'legion/logging/helper'

module Legion
  module LLM
    module API
      extend Legion::Logging::Helper

      def self.registered(app)
        InventoryAdmin.registered(app)
        if Legion::Settings.dig(:llm, :api, :use_namespaces) == false
          # L3 (R10 explicit compatibility edge, annotated): the flat legacy
          # tree is a second HTTP surface for the same operations — dial-gated,
          # deprecated, and warn-logged below. Its deletion is the coordinated
          # legacy-surface cleanup wave (audit close order #4, with the sibling
          # repos' P6 and #154): the tree consumes the legacy Dispatch.call and
          # Types::* response world that wave removes, so the rip is
          # multi-repo, not a unilateral deletion here.
          log.warn(
            '[llm][api] routing=legacy DEPRECATED — the flat api/{anthropic,openai,native}/ tree ' \
            'will be deleted next minor; flip llm.api.use_namespaces back to true (the default) ' \
            'to register the namespaced routes instead'
          )
          register_legacy(app)
        else
          log.debug('[llm][api] routing=namespaces registering via Namespaces::Registration')
          Namespaces::Registration.registered(app)
        end
        log.debug('[llm][api] all routes registered')
      end

      def self.register_routes
        return unless defined?(Legion::API) && Legion::API.respond_to?(:register_library_routes)

        Legion::API.register_library_routes('llm', self)
        log.debug('[llm][api] routes registered with Legion::API')
      end

      def self.register_legacy(app)
        Auth.registered(app)
        Native::Helpers.registered(app)
        Native::Inference.registered(app)
        Native::Chat.registered(app)
        Native::Providers.registered(app)
        Native::Models.registered(app)
        Native::Offerings.registered(app)
        Native::Instances.registered(app)
        Native::Routing.registered(app)
        Native::Tiers.registered(app)
        OpenAI::ChatCompletions.registered(app)
        OpenAI::Models.registered(app)
        OpenAI::Embeddings.registered(app)
        OpenAI::Responses.registered(app)
        Anthropic::Messages.registered(app)
      end
      private_class_method :register_legacy
    end

    Routes = API
  end
end
