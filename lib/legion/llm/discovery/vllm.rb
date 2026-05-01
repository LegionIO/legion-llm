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
            all_models
          end

          def model_names
            models.map { |m| config_value(m, :id) }
          end

          def model_available?(name, instance: nil)
            if instance
              ensure_fresh
              list = models_for(instance: instance)
              list.any? { |m| config_value(m, :id) == name }
            else
              model_names.any? { |n| n == name }
            end
          end

          def max_context(name, instance: nil)
            target = instance ? models_for(instance: instance) : models
            model = target.find { |m| config_value(m, :id) == name }
            config_value(model, :max_model_len)
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

          def healthy?(instance: nil)
            instances = resolved_instances
            if instance
              cfg = instances[instance.to_sym]
              return false unless cfg

              base = cfg[:base_url] || cfg['base_url'] || 'http://localhost:8000/v1'
              check_health(base)
            else
              instances.any? { |_id, cfg| check_health(cfg[:base_url] || cfg['base_url'] || 'http://localhost:8000/v1') }
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

            @models_by_instance.values.flatten(1).uniq { |m| config_value(m, :id) }
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

            vllm_config = config_value(providers_settings, :vllm, {})
            config_value(vllm_config, :instances)
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
            return 'http://localhost:8000/v1' unless Legion.const_defined?('Settings', false)

            config_value(config_value(providers_settings, :vllm, {}), :base_url, 'http://localhost:8000/v1')
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.discovery.vllm.base_url')
            'http://localhost:8000/v1'
          end

          def scan_instances_parallel(instances)
            @models_by_instance ||= {}
            @last_refreshed_by_instance ||= {}

            threads = instances.map do |id, cfg|
              Thread.new(id, cfg) do |inst_id, inst_cfg|
                base = inst_cfg[:base_url] || inst_cfg['base_url'] || 'http://localhost:8000/v1'
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
            response = conn.get('/v1/models')
            if response.success?
              parsed = Legion::JSON.load(response.body)
              model_list = parsed[:data] || []
              log.debug "[llm][discovery][vllm] model list refreshed url=#{base_url} count=#{model_list.size}"
              model_list
            else
              log.warn "[llm][discovery][vllm] HTTP failure url=#{base_url} status=#{response.status}"
              []
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.discovery.vllm.refresh')
            []
          end

          def check_health(base_url)
            health_base = base_url.sub(%r{/+\z}, '').sub(%r{/v1\z}, '')
            conn = Faraday.new(url: health_base) do |f|
              f.options.timeout = 2
              f.options.open_timeout = 2
              f.adapter Faraday.default_adapter
            end
            response = conn.get('/health')
            response.success?
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.discovery.vllm.healthy')
            false
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
