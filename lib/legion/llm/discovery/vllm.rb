# frozen_string_literal: true

require 'faraday'

require 'legion/logging/helper'
require 'legion/json'

module Legion
  module LLM
    module Discovery
      module Vllm
        extend Legion::Logging::Helper

        class << self
          def models
            ensure_fresh
            @models || []
          end

          def model_names
            models.map { |m| m[:id] }
          end

          def model_available?(name)
            model_names.any? { |n| n == name }
          end

          def max_context(name)
            model = models.find { |m| m[:id] == name }
            model&.dig(:max_model_len)
          end

          def healthy?
            response = health_connection.get('/health')
            response.success?
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.discovery.vllm.healthy')
            false
          end

          def refresh!
            response = connection.get('/v1/models')
            if response.success?
              parsed = Legion::JSON.load(response.body)
              @models = parsed[:data] || []
              log.debug "[llm][discovery][vllm] model list refreshed count=#{@models.size}"
            else
              log.warn "[llm][discovery][vllm] HTTP failure status=#{response.status}"
              @models ||= []
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.discovery.vllm.refresh')
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
            Faraday.new(url: vllm_base_url) do |f|
              f.options.timeout = 3
              f.options.open_timeout = 2
              f.adapter Faraday.default_adapter
            end
          end

          def health_connection
            base = vllm_base_url.sub(%r{/+\z}, '').sub(%r{/v1\z}, '')
            Faraday.new(url: base) do |f|
              f.options.timeout = 2
              f.options.open_timeout = 2
              f.adapter Faraday.default_adapter
            end
          end

          def vllm_base_url
            return 'http://localhost:8000/v1' unless Legion.const_defined?('Settings', false)

            Legion::Settings[:llm].dig(:providers, :vllm, :base_url) || 'http://localhost:8000/v1'
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.discovery.vllm.base_url')
            'http://localhost:8000/v1'
          end

          def discovery_settings
            return {} unless Legion.const_defined?('Settings', false)

            Legion::Settings[:llm][:discovery] || {}
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.discovery.vllm.settings')
            {}
          end
        end
      end
    end
  end
end
