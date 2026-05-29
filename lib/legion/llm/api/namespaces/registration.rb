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

          def self.register_native(app)
            log.debug('[llm][api][namespaces] registering native routes')

            require_relative 'native/providers'
            require_relative 'native/instances'
            require_relative 'native/models'
            require_relative 'native/offerings'
            require_relative 'native/routing'
            require_relative 'native/tiers'
            require_relative 'native/chat'
            require_relative 'native/inference'

            app.namespace '/api/llm/providers' do
              register Namespaces::Native::Providers
            end

            app.namespace '/api/llm/instances' do
              register Namespaces::Native::Instances
            end

            app.namespace '/api/llm/models' do
              register Namespaces::Native::Models
            end

            # Cross-namespace route: /api/llm/providers/:name/models
            # Must be registered at full path, not inside either namespace
            app.get '/api/llm/providers/:name/models' do
              provider = params[:name]
              log.debug("[llm][api][namespaces][models] action=list_provider_models provider=#{provider}")
              require_llm!

              filters = Legion::LLM::API::Native::Models.request_filters(params).merge(provider: provider)
              offerings = Legion::LLM::Inventory.offerings(filters)

              json_response({
                              provider:  provider,
                              models:    Legion::LLM::API::Native::Models.model_summaries(offerings),
                              offerings: offerings,
                              summary:   Legion::LLM::API::Native::Models.summary(offerings)
                            })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.models.provider')
              json_error('model_inventory_error', e.message, status_code: 500)
            end

            app.namespace '/api/llm/offerings' do
              register Namespaces::Native::Offerings
            end

            app.namespace '/api/llm/routing' do
              register Namespaces::Native::Routing
            end

            app.namespace '/api/llm/tiers' do
              register Namespaces::Native::Tiers
            end

            app.namespace '/api/llm/chat' do
              register Namespaces::Native::Chat
            end

            app.namespace '/api/llm/inference' do
              register Namespaces::Native::Inference
            end

            log.debug('[llm][api][namespaces] native routes registered')
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
            require_relative 'anthropic/files'
            # NOTE: anthropic/models.rb is a format helper only — no routes to register.
            # The /v1/models namespace is owned by OpenAI::Models (Phase 2A) which branches
            # on anthropic_client?(env) to emit Anthropic-format responses.

            app.namespace '/v1/messages' do
              register Namespaces::Anthropic::Messages
              register Namespaces::Anthropic::Messages::CountTokens
              namespace('/batches') { register Namespaces::Anthropic::Messages::Batches }
            end

            app.namespace '/v1/files' do
              register Namespaces::Anthropic::Files
            end

            log.debug('[llm][api][namespaces] anthropic namespaces registered')
          end
        end
      end
    end
  end
end
