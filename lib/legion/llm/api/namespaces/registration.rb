# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/namespace'
require 'legion/logging/helper'
require_relative 'helpers'

module Legion
  module LLM
    module API
      module Namespaces
        module Registration
          extend Legion::Logging::Helper

          def self.registered(app)
            log.debug('[llm][api][namespaces] registering namespace routes')
            app.register Sinatra::Namespace
            app.helpers Helpers

            register_native(app)
            register_openai(app)
            register_anthropic(app)

            log.debug('[llm][api][namespaces] all namespace routes registered')
          end

          def self.register_native(_app)
            log.debug('[llm][api][namespaces] native namespace registration pending')
          end

          def self.register_openai(app)
            log.debug('[llm][api][namespaces] registering openai namespaces')

            require_relative 'openai/responses'
            require_relative 'openai/chat/completions'
            require_relative 'openai/chat/messages'
            require_relative 'openai/models'
            require_relative 'openai/embeddings'
            require_relative 'openai/completions'

            app.register OpenAI::Responses
            app.register OpenAI::Chat::Completions
            app.register OpenAI::Chat::Messages
            app.register OpenAI::Models
            app.register OpenAI::Embeddings
            app.register OpenAI::Completions

            log.debug('[llm][api][namespaces] openai namespaces registered')
          end

          def self.register_anthropic(app)
            require_relative 'anthropic/messages'
            require_relative 'anthropic/messages/count_tokens'
            require_relative 'anthropic/messages/batches'
            # NOTE: anthropic/models.rb is a format helper only — no routes to register.
            # The /v1/models namespace is owned by OpenAI::Models (Phase 2A) which branches
            # on anthropic_client?(env) to emit Anthropic-format responses.

            app.namespace '/v1/messages' do
              register Namespaces::Anthropic::Messages
              register Namespaces::Anthropic::Messages::CountTokens
              namespace('/batches') { register Namespaces::Anthropic::Messages::Batches }
            end

            log.debug('[llm][api][namespaces] anthropic namespaces registered')
          end
        end
      end
    end
  end
end
