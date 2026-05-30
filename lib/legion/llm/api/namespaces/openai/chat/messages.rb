# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/api/namespaces/helpers'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Chat
            module Messages
              extend Legion::Logging::Helper

              def self.registered(app)
                log.debug('[llm][api][namespaces][openai][chat][messages] registering routes')

                app.get '/v1/chat/completions/:completion_id/messages' do
                  completion_id = params[:completion_id]
                  log.debug("[llm][api][namespaces][openai][chat][messages] action=list completion_id=#{completion_id}")

                  content_type :json
                  Legion::JSON.dump({ object: 'list', data: [], has_more: false, first_id: nil, last_id: nil })
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.chat.messages')
                  openai_error(e.message, type: 'server_error', status_code: 500)
                end

                log.debug('[llm][api][namespaces][openai][chat][messages] routes registered')
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.namespaces.openai.chat.messages.register')
              end
            end
          end
        end
      end
    end
  end
end
