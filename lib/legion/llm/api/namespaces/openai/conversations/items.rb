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
            module Items
              extend Legion::Logging::Helper

              def self.registered(app) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
                log.debug('[llm][api][namespaces][openai][items] registering routes')

                # POST /v1/conversations/:id/items
                app.post '/v1/conversations/:id/items' do
                  require_llm!
                  conv_id = params[:id]
                  body    = parse_request_body
                  validate_required!(body, :role, :content)

                  unless Inference::Conversation.conversation_exists?(conv_id)
                    halt 404, { 'Content-Type' => 'application/json' },
                         Legion::JSON.dump({ error: { message: "Conversation '#{conv_id}' not found.",
                                                      type: 'invalid_request_error', code: 'conversation_not_found' } })
                  end

                  role    = body[:role].to_sym
                  content = body[:content]

                  msg = Inference::Conversation.append(conv_id, role: role, content: content)
                  log.debug("[llm][api][openai][items] action=create conv_id=#{conv_id} item_id=#{msg[:id]} role=#{role}")

                  content_type :json
                  status 200
                  Legion::JSON.dump({
                                      id:         msg[:id],
                                      object:     'conversation.item',
                                      conv_id:    conv_id,
                                      role:       role.to_s,
                                      content:    content,
                                      created_at: msg[:created_at].to_i
                                    })
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.items.create')
                  openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
                end

                # GET /v1/conversations/:id/items (list)
                app.get '/v1/conversations/:id/items' do
                  require_llm!
                  conv_id = params[:id]
                  limit   = params[:limit]&.to_i || 100
                  after   = params[:after]

                  unless Inference::Conversation.conversation_exists?(conv_id)
                    halt 404, { 'Content-Type' => 'application/json' },
                         Legion::JSON.dump({ error: { message: "Conversation '#{conv_id}' not found.",
                                                      type: 'invalid_request_error', code: 'conversation_not_found' } })
                  end

                  # Check conversation tombstone
                  conv_meta = Inference::Conversation.read_metadata(conv_id) || {}
                  if conv_meta[:title] == '__deleted__'
                    halt 404, { 'Content-Type' => 'application/json' },
                         Legion::JSON.dump({ error: { message: "Conversation '#{conv_id}' not found.",
                                                      type: 'invalid_request_error', code: 'conversation_not_found' } })
                  end

                  msgs = Inference::Conversation.messages(conv_id)
                  msgs = msgs.reject { |m| m[:__deleted__] }

                  if after
                    idx = msgs.index { |m| m[:id] == after }
                    msgs = msgs[(idx + 1)..] if idx
                  end

                  msgs = msgs.first(limit)
                  log.debug("[llm][api][openai][items] action=list conv_id=#{conv_id} count=#{msgs.size}")

                  content_type :json
                  status 200
                  Legion::JSON.dump({
                                      object:   'list',
                                      data:     msgs.map { |m| Items.serialize_item(m, conv_id) },
                                      has_more: false,
                                      first_id: msgs.first&.dig(:id),
                                      last_id:  msgs.last&.dig(:id)
                                    })
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.items.list')
                  openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
                end

                # GET /v1/conversations/:id/items/:item_id
                app.get '/v1/conversations/:id/items/:item_id' do
                  require_llm!
                  conv_id = params[:id]
                  item_id = params[:item_id]

                  unless Inference::Conversation.conversation_exists?(conv_id)
                    halt 404, { 'Content-Type' => 'application/json' },
                         Legion::JSON.dump({ error: { message: "Conversation '#{conv_id}' not found.",
                                                      type: 'invalid_request_error', code: 'conversation_not_found' } })
                  end

                  msgs = Inference::Conversation.raw_messages(conv_id)
                  msg  = msgs.find { |m| m[:id] == item_id }

                  unless msg
                    halt 404, { 'Content-Type' => 'application/json' },
                         Legion::JSON.dump({ error: { message: "Item '#{item_id}' not found.",
                                                      type: 'invalid_request_error', code: 'item_not_found' } })
                  end

                  log.debug("[llm][api][openai][items] action=get item_id=#{item_id}")
                  content_type :json
                  status 200
                  Legion::JSON.dump(Items.serialize_item(msg, conv_id))
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.items.get')
                  openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
                end

                # DELETE /v1/conversations/:id/items/:item_id
                app.delete '/v1/conversations/:id/items/:item_id' do
                  require_llm!
                  conv_id = params[:id]
                  item_id = params[:item_id]

                  unless Inference::Conversation.conversation_exists?(conv_id)
                    halt 404, { 'Content-Type' => 'application/json' },
                         Legion::JSON.dump({ error: { message: "Conversation '#{conv_id}' not found.",
                                                      type: 'invalid_request_error', code: 'conversation_not_found' } })
                  end

                  msgs = Inference::Conversation.raw_messages(conv_id)
                  msg  = msgs.find { |m| m[:id] == item_id }

                  unless msg
                    halt 404, { 'Content-Type' => 'application/json' },
                         Legion::JSON.dump({ error: { message: "Item '#{item_id}' not found.",
                                                      type: 'invalid_request_error', code: 'item_not_found' } })
                  end

                  # Tombstone: mark deleted; item stays in chain but hidden from normal list
                  msg[:__deleted__] = true
                  log.debug("[llm][api][openai][items] action=delete item_id=#{item_id}")

                  content_type :json
                  status 200
                  Legion::JSON.dump({ id: item_id, object: 'conversation.item', deleted: true })
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.items.delete')
                  openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
                end

                log.debug('[llm][api][namespaces][openai][items] routes registered')
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.items.register')
              end

              def self.serialize_item(msg, conv_id)
                {
                  id:         msg[:id],
                  object:     'conversation.item',
                  conv_id:    conv_id,
                  role:       msg[:role].to_s,
                  content:    msg[:content],
                  created_at: msg[:created_at]&.to_i
                }
              end
            end
          end
        end
      end
    end
  end
end
