# frozen_string_literal: true

require 'faraday'
require 'json'

require 'legion/logging/helper'
module Legion
  module LLM
    module Discovery
      module Ollama
        extend Legion::Logging::Helper

        class << self
          def models
            ensure_fresh
            all_models
          end

          def model_names
            models.map { |m| m['name'] }
          end

          def model_available?(name, instance: nil)
            if instance
              ensure_fresh
              list = models_for(instance: instance)
              list.any? { |m| m['name'] == name || m['name'].start_with?("#{name}:") }
            else
              model_names.any? { |n| n == name || n.start_with?("#{name}:") }
            end
          end

          def model_size(name, instance: nil)
            if instance
              ensure_fresh
              models_for(instance: instance)
                .find { |m| m['name'] == name || m['name'].start_with?("#{name}:") }
                &.dig('size')
            else
              models.find { |m| m['name'] == name || m['name'].start_with?("#{name}:") }&.dig('size')
            end
          end

          def models_for(instance:)
            ensure_fresh
            (@models_by_instance || {})[instance.to_sym] || []
          end

          def scan_all_instances
            instances = resolved_instances
            scan_instances_parallel(instances)
            instances.each_with_object({}) do |(id, cfg), result|
              result[id] = { models: (@models_by_instance || {})[id] || [], base_url: cfg[:base_url] || cfg['base_url'] }
            end
          end

          def refresh!
            instances = resolved_instances
            scan_instances_parallel(instances)
          end

          def reset!
            @models_by_instance = nil
            @last_refreshed_by_instance = nil
          end

          def stale?
            return true if @last_refreshed_by_instance.nil? || @last_refreshed_by_instance.empty?

            ttl = config_value(discovery_settings, :refresh_seconds, 60)
            @last_refreshed_by_instance.values.any? { |t| Time.now - t > ttl }
          end

          private

          def ensure_fresh
            refresh! if stale?
          end

          def all_models
            return [] if @models_by_instance.nil? || @models_by_instance.empty?

            @models_by_instance.values.flatten(1).uniq { |m| m['name'] }
          end

          def resolved_instances
            instances = read_instances_setting
            if instances.is_a?(Hash) && !instances.empty?
              normalize_instances(instances)
            else
              { default: { base_url: flat_base_url } }
            end
          end

          def read_instances_setting
            return nil unless Legion.const_defined?('Settings', false)

            ollama_config = config_value(providers_settings, :ollama, {})
            config_value(ollama_config, :instances)
          rescue StandardError => e
            handle_exception(e, level: :debug)
            nil
          end

          def normalize_instances(raw)
            raw.each_with_object({}) do |(id, cfg), hash|
              hash[id.to_sym] = cfg.is_a?(Hash) ? cfg : { base_url: cfg.to_s }
            end
          end

          def flat_base_url
            return 'http://localhost:11434' unless Legion.const_defined?('Settings', false)

            config_value(config_value(providers_settings, :ollama, {}), :base_url, 'http://localhost:11434')
          rescue StandardError => e
            handle_exception(e, level: :debug)
            'http://localhost:11434'
          end

          def scan_instances_parallel(instances)
            @models_by_instance ||= {}
            @last_refreshed_by_instance ||= {}

            threads = instances.map do |id, cfg|
              Thread.new(id, cfg) do |inst_id, inst_cfg|
                base = inst_cfg[:base_url] || inst_cfg['base_url'] || 'http://localhost:11434'
                [inst_id, fetch_models(base)]
              end
            end

            deadline = Time.now + 5
            threads.each do |t|
              remaining = [deadline - Time.now, 0].max
              t.join(remaining)
              if t.alive?
                t.kill
              elsif t.value
                inst_id, result = t.value
                @models_by_instance[inst_id] = result
                @last_refreshed_by_instance[inst_id] = Time.now
              end
            end
          end

          def fetch_models(base_url)
            conn = Faraday.new(url: base_url) do |f|
              f.options.timeout = 2
              f.options.open_timeout = 2
              f.adapter Faraday.default_adapter
            end
            response = conn.get('/api/tags')
            if response.success?
              parsed = ::JSON.parse(response.body)
              models = parsed['models'] || []
              log.debug("Discovery::Ollama model list refreshed url=#{base_url} count=#{models.size}")
              models
            else
              log.warn("Discovery::Ollama HTTP failure url=#{base_url} status=#{response.status}")
              []
            end
          rescue StandardError => e
            handle_exception(e, level: :warn)
            []
          end

          def discovery_settings
            return {} unless Legion.const_defined?('Settings', false)

            config_value(llm_settings, :discovery, {})
          rescue StandardError => e
            handle_exception(e, level: :debug)
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
