# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'
require 'legion/llm/api/namespaces/helpers'
require 'legion/llm/inference/conversation'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Conversations
            extend Legion::Logging::Helper

            def self.registered(app) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
              log.debug('[llm][api][namespaces][openai][conversations] registering routes')

              app.post '/v1/conversations' do
                require_llm!
                body = parse_request_body
                conv_id = "conv_#{SecureRandom.hex(16)}"

                model = body[:model].to_s
                title = body.dig(:metadata, :title)
                meta  = body[:metadata] || {}

                Inference::Conversation.create_conversation(conv_id)
                Inference::Conversation.store_metadata(conv_id, title: title, model: model.empty? ? nil : model)

                log.debug("[llm][api][openai][conversations] action=create conv_id=#{conv_id} model=#{model}")

                content_type :json
                status 200
                Legion::JSON.dump({
                  id:         conv_id,
                  object:     'conversation',
                  created_at: Time.now.to_i,
                  model:      model.empty? ? nil : model,
                  metadata:   meta
                }.compact)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.conversations.create')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              app.get '/v1/conversations/:id' do
                require_llm!
                conv_id = params[:id]

                unless Inference::Conversation.conversation_exists?(conv_id)
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "Conversation '#{conv_id}' not found.",
                                                    type: 'invalid_request_error', code: 'conversation_not_found' } })
                end

                meta = Inference::Conversation.read_metadata(conv_id) || {}

                # Tombstone check — conversation was deleted via DELETE /:id
                if meta[:title] == '__deleted__'
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "Conversation '#{conv_id}' not found.",
                                                    type: 'invalid_request_error', code: 'conversation_not_found' } })
                end

                msg_count = Inference::Conversation.messages(conv_id).size

                log.debug("[llm][api][openai][conversations] action=get conv_id=#{conv_id} messages=#{msg_count}")

                content_type :json
                status 200
                Legion::JSON.dump({
                  id:            conv_id,
                  object:        'conversation',
                  created_at:    nil,
                  model:         meta[:model],
                  title:         meta[:title],
                  message_count: msg_count
                }.compact)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.conversations.get')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              app.post '/v1/conversations/:id' do
                require_llm!
                conv_id = params[:id]
                body    = parse_request_body

                unless Inference::Conversation.conversation_exists?(conv_id)
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "Conversation '#{conv_id}' not found.",
                                                    type: 'invalid_request_error', code: 'conversation_not_found' } })
                end

                new_meta = body[:metadata] || {}
                title    = new_meta[:title]
                model    = new_meta[:model] || body[:model]

                Inference::Conversation.store_metadata(conv_id, title: title, model: model)
                log.debug("[llm][api][openai][conversations] action=update conv_id=#{conv_id}")

                content_type :json
                status 200
                Legion::JSON.dump(
                  {
                    id:       conv_id,
                    object:   'conversation',
                    metadata: new_meta
                  }
                )
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.conversations.update')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              app.delete '/v1/conversations/:id' do
                require_llm!
                conv_id = params[:id]

                unless Inference::Conversation.conversation_exists?(conv_id)
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "Conversation '#{conv_id}' not found.",
                                                    type: 'invalid_request_error', code: 'conversation_not_found' } })
                end

                # Tombstone strategy: mark this specific conversation as deleted.
                # GET /:id checks for tombstone and treats it as gone.
                Inference::Conversation.store_metadata(conv_id, title: '__deleted__')
                log.debug("[llm][api][openai][conversations] action=delete conv_id=#{conv_id}")

                content_type :json
                status 200
                Legion::JSON.dump({ id: conv_id, object: 'conversation', deleted: true })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.conversations.delete')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              log.debug('[llm][api][namespaces][openai][conversations] routes registered')
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.conversations.register')
            end
          end
        end
      end
    end
  end
end
