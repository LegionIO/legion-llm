# frozen_string_literal: true

require 'time'
require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module OpenAI
        module Models
          extend Legion::Logging::Helper

          PROVIDER_DEFAULT_MODELS = {
            bedrock:   'us.anthropic.claude-sonnet-4-6-v1',
            anthropic: 'claude-sonnet-4-6',
            openai:    'gpt-4o',
            gemini:    'gemini-2.0-flash',
            azure:     nil,
            ollama:    'llama3'
          }.freeze

          def self.registered(app)
            log.debug('[llm][api][openai][models] registering GET /v1/models and GET /v1/models/:id')

            app.get '/v1/models' do
              log.debug('[llm][api][openai][models] action=list')
              require_llm!

              model_list = Legion::LLM::API::OpenAI::Models.build_model_list
              log.debug("[llm][api][openai][models] action=listed count=#{model_list.size}")

              content_type :json
              Legion::JSON.dump({ object: 'list', data: model_list })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.models.list')
              halt 500, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })
            end

            app.get '/v1/models/:id' do
              model_id = params[:id]
              log.debug("[llm][api][openai][models] action=get id=#{model_id}")
              require_llm!

              model_list = Legion::LLM::API::OpenAI::Models.build_model_list
              found = model_list.find { |m| m[:id] == model_id }

              unless found
                log.debug("[llm][api][openai][models] action=not_found id=#{model_id}")
                halt 404, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: "Model '#{model_id}' not found",
                                                  type: 'invalid_request_error', code: 'model_not_found' } })
              end

              log.debug("[llm][api][openai][models] action=found id=#{model_id}")
              content_type :json
              Legion::JSON.dump(found)
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.models.get')
              halt 500, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error' } })
            end

            log.debug('[llm][api][openai][models] GET /v1/models routes registered')
          end

          def self.build_model_list
            models = []

            models.concat(models_from_discovery)
            models.concat(models_from_providers)

            seen = {}
            models.select { |m| seen[m[:id]] ? false : (seen[m[:id]] = true) }
          end

          def self.models_from_discovery
            return [] unless defined?(Legion::LLM::Discovery::Ollama) &&
                             Legion::LLM::Discovery::Ollama.respond_to?(:available_models)

            Legion::LLM::Discovery::Ollama.available_models.map do |model_id|
              Legion::LLM::API::Translators::OpenAIResponse.format_model_object(model_id, owned_by: 'ollama')
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.api.openai.models.discovery')
            []
          end

          def self.models_from_providers
            providers_config = Legion::LLM.settings.fetch(:providers, {})
            providers_config.filter_map do |name, config|
              next unless config.is_a?(Hash) && config[:enabled] != false

              model_id = config[:default_model] || PROVIDER_DEFAULT_MODELS[name.to_sym]
              next unless model_id

              Legion::LLM::API::Translators::OpenAIResponse.format_model_object(
                model_id, owned_by: name.to_s
              )
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.api.openai.models.providers')
            []
          end
        end
      end
    end
  end
end
