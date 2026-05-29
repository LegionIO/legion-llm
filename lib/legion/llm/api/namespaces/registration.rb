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

          def self.register_openai(_app)
            log.debug('[llm][api][namespaces] openai namespace registration pending')
          end

          def self.register_anthropic(_app)
            log.debug('[llm][api][namespaces] anthropic namespace registration pending')
          end
        end
      end
    end
  end
end
