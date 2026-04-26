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
            models.map { |m| config_value(m, :id) }
          end

          def model_available?(name)
            model_names.any? { |n| n == name }
          end

          def max_context(name)
            model = models.find { |m| config_value(m, :id) == name }
            config_value(model, :max_model_len)
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

            ttl = config_value(discovery_settings, :refresh_seconds, 60)
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

            config_value(config_value(providers_settings, :vllm, {}), :base_url, 'http://localhost:8000/v1')
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.discovery.vllm.base_url')
            'http://localhost:8000/v1'
          end

          def discovery_settings
            return {} unless Legion.const_defined?('Settings', false)

            config_value(llm_settings, :discovery, {})
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.discovery.vllm.settings')
            {}
          end

          def providers_settings
            config_value(llm_settings, :providers, {})
          end

          def llm_settings
            Legion::LLM::Settings.current_settings
          end

          def config_value(config, key, default = nil)
            return default unless config.respond_to?(:key?)

            string_key = key.to_s
            return config[string_key] if config.key?(string_key)

            symbol_key = key.to_sym if key.respond_to?(:to_sym)
            return config[symbol_key] if symbol_key && config.key?(symbol_key)

            default
          end
        end
      end
    end
  end
end
