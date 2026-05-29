# frozen_string_literal: true

require 'time'
require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module OpenAI
        module Models
          extend Legion::Logging::Helper

          def self.registered(app)
            log.debug('[llm][api][openai][models] registering GET /v1/models + /api/llm/inference/v1/models routes')

            list_handler = proc do
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

            get_handler = proc do
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

            app.get('/v1/models') { instance_exec(&list_handler) }
            app.get('/api/llm/inference/v1/models') { instance_exec(&list_handler) }
            app.get('/v1/models/:id') { instance_exec(&get_handler) }
            app.get('/api/llm/inference/v1/models/:id') { instance_exec(&get_handler) }

            log.debug('[llm][api][openai][models] routes registered')
          end

          def self.build_model_list
            models = Legion::LLM::Inventory.offerings(type: :inference).map do |offering|
              Legion::LLM::API::Translators::OpenAIResponse.format_model_object(
                offering[:model],
                owned_by: offering[:provider_family]
              )
            end
            seen = {}
            models.select { |m| seen[m[:id]] ? false : (seen[m[:id]] = true) }
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.api.openai.models.inventory')
            []
          end
        end
      end
    end
  end
end
