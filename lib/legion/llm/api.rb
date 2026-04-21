# frozen_string_literal: true

require_relative 'api/native/inference'

module Legion
  module LLM
    module API
      def self.registered(app)
        Legion::LLM::Routes.registered(app)
      end

      def self.register_routes
        return unless defined?(Legion::API) && Legion::API.respond_to?(:register_library_routes)

        Legion::API.register_library_routes('llm', Legion::LLM::Routes)
      end
    end
  end
end
