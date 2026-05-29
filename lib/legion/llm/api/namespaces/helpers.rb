# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/llm/api/shared_helpers'

module Legion
  module LLM
    module API
      module Namespaces
        module Helpers
          include Legion::LLM::API::SharedHelpers

          def openai_error(message, type: 'server_error', code: nil, status_code: 500)
            content_type :json
            status status_code
            body = { error: { message: message, type: type } }
            body[:error][:code] = code if code
            Legion::JSON.dump(body)
          end

          def anthropic_error(error_type, message, status_code: 500)
            content_type :json
            status status_code
            Legion::JSON.dump({ type: 'error', error: { type: error_type, message: message } })
          end

          def detect_client(rack_env)
            return :anthropic if rack_env['HTTP_ANTHROPIC_VERSION']
            return :anthropic if rack_env['HTTP_X_API_KEY'] && !rack_env['HTTP_AUTHORIZATION']

            :openai
          end
        end
      end
    end
  end
end
