# frozen_string_literal: true

require 'faraday'
require 'json'

module Legion
  module LLM
    module Discovery
      module Ollama
        class << self
          def models
            ensure_fresh
            @models || []
          end

          def model_names
            models.map { |m| m['name'] }
          end

          def model_available?(name)
            model_names.include?(name)
          end

          def model_size(name)
            models.find { |m| m['name'] == name }&.dig('size')
          end

          def refresh!
            response = connection.get('/api/tags')
            if response.success?
              parsed = ::JSON.parse(response.body)
              @models = parsed['models'] || []
            else
              @models ||= []
            end
          rescue StandardError
            @models ||= []
          ensure
            @last_refreshed_at = Time.now
          end

          def reset!
            @models = nil
            @last_refreshed_at = nil
          end

          def stale?
            return true if @last_refreshed_at.nil?

            ttl = discovery_settings[:refresh_seconds] || 60
            Time.now - @last_refreshed_at > ttl
          end

          private

          def ensure_fresh
            refresh! if stale?
          end

          def connection
            base = ollama_base_url
            Faraday.new(url: base) do |f|
              f.options.timeout = 2
              f.options.open_timeout = 2
              f.adapter Faraday.default_adapter
            end
          end

          def ollama_base_url
            return 'http://localhost:11434' unless Legion.const_defined?('Settings')

            Legion::Settings[:llm].dig(:providers, :ollama, :base_url) || 'http://localhost:11434'
          rescue StandardError
            'http://localhost:11434'
          end

          def discovery_settings
            return {} unless Legion.const_defined?('Settings')

            Legion::Settings[:llm][:discovery] || {}
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end
