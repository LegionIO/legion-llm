# frozen_string_literal: true

require 'faraday'
require 'legion/json'

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
            models.map { |m| m[:name] }
          end

          def model_available?(name, instance: nil)
            if instance
              ensure_fresh
              list = models_for(instance: instance)
              list.any? { |m| m[:name] == name || m[:name].start_with?("#{name}:") }
            else
              model_names.any? { |n| n == name || n.start_with?("#{name}:") }
            end
          end

          def model_size(name, instance: nil)
            if instance
              ensure_fresh
              models_for(instance: instance)
                .find { |m| m[:name] == name || m[:name].start_with?("#{name}:") }
                &.dig(:size)
            else
              models.find { |m| m[:name] == name || m[:name].start_with?("#{name}:") }&.dig(:size)
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
              base_url = cfg[:base_url] || cfg['base_url']
              models = (@models_by_instance || {})[id] || []
              instance_data = { models: models, base_url: base_url }

              # Pass through per-instance filter config for RuleGenerator
              wl = cfg[:model_whitelist] || cfg['model_whitelist']
              bl = cfg[:model_blacklist] || cfg['model_blacklist']
              instance_data[:model_whitelist] = Array(wl) if wl
              instance_data[:model_blacklist] = Array(bl) if bl

              # Enrich models with /api/show metadata (capabilities, context_length, etc.)
              enrich_instance_models!(id, base_url, models, wl.is_a?(Array) ? wl : nil, bl.is_a?(Array) ? bl : nil)

              result[id] = instance_data
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

            ttl = Legion::LLM::Settings.config_value(discovery_settings, :refresh_seconds, 60)
            @last_refreshed_by_instance.values.any? { |t| Time.now - t > ttl }
          end

          private

          def ensure_fresh
            refresh! if stale?
          end

          def all_models
            return [] if @models_by_instance.nil? || @models_by_instance.empty?

            @models_by_instance.values.flatten(1).uniq { |m| m[:name] }
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

            ollama_config = Legion::LLM::Settings.config_value(providers_settings, :ollama, {})
            Legion::LLM::Settings.config_value(ollama_config, :instances)
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

            Legion::LLM::Settings.config_value(
              Legion::LLM::Settings.config_value(providers_settings, :ollama, {}), :base_url, 'http://localhost:11434'
            )
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

          def enrich_instance_models!(instance_id, base_url, models, whitelist, blacklist)
            global_wl = routing_model_whitelist
            global_bl = routing_model_blacklist
            effective_wl = whitelist || global_wl
            effective_bl = blacklist || global_bl

            # Only enrich models that pass filters to avoid unnecessary API calls
            eligible_names = models.filter_map do |m|
              name = m[:name]
              next nil if name.nil? || name.empty?
              next nil if effective_wl&.any? && effective_wl.none? { |pat| name.downcase.include?(pat.downcase) }
              next nil if effective_bl&.any? && effective_bl.any? { |pat| name.downcase.include?(pat.downcase) }

              name
            end

            return if eligible_names.empty?

            enriched = enrich_models_parallel(instance_id, base_url, eligible_names)
            apply_enrichment!(models, enriched)
          rescue StandardError => e
            handle_exception(e, level: :debug)
          end

          def enrich_models_parallel(instance_id, base_url, model_names)
            enriched = {}
            deadline = Time.now + 10

            model_names.each do |name|
              break if Time.now > deadline

              begin
                show_data = fetch_model_show(base_url, name)
                enriched[name] = show_data if show_data
              rescue Exception # rubocop:disable Lint/RescueException
                # Best-effort: skip any model that fails enrichment
                next
              end
            end

            log.debug("Discovery::Ollama enriched #{enriched.size}/#{model_names.size} models for instance=#{instance_id}")
            enriched
          rescue StandardError => e
            handle_exception(e, level: :debug)
            enriched || {}
          end

          def apply_enrichment!(models, enriched)
            models.each do |m|
              show_data = enriched[m[:name]]
              next unless show_data

              m[:capabilities]    = show_data[:capabilities] if show_data[:capabilities]
              m[:context_length]  = show_data[:context_length] if show_data[:context_length]
              m[:parameter_count] = show_data[:parameter_count] if show_data[:parameter_count]
              m[:parameter_size]  = show_data[:parameter_size] if show_data[:parameter_size]
              m[:quantization]    = show_data[:quantization] if show_data[:quantization]
              m[:family]          = show_data[:family] if show_data[:family]
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
              parsed = Legion::JSON.parse(response.body)
              models = parsed[:models] || []
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

          def fetch_model_show(base_url, model_name)
            conn = Faraday.new(url: base_url) do |f|
              f.options.timeout = 2
              f.options.open_timeout = 2
              f.adapter Faraday.default_adapter
            end
            response = conn.post('/api/show', Legion::JSON.generate({ model: model_name }),
                                 'Content-Type' => 'application/json')
            return nil unless response.success?

            parsed = Legion::JSON.parse(response.body)
            parse_show_response(parsed)
          rescue StandardError => e
            handle_exception(e, level: :debug)
            nil
          end

          def parse_show_response(data)
            result = {}
            caps = data[:capabilities]
            result[:capabilities] = caps.map { |c| c.to_s.to_sym } if caps.is_a?(Array) && caps.any?

            details = data[:details] || {}
            result[:parameter_size] = details[:parameter_size] if details[:parameter_size]
            result[:quantization]   = details[:quantization_level] if details[:quantization_level]
            result[:family]         = details[:family] if details[:family]

            model_info = data[:model_info] || {}
            param_count = model_info[:'general.parameter_count']
            result[:parameter_count] = param_count if param_count

            # Find context_length from model_info keys like "qwen35.context_length" or "llama.context_length"
            ctx_key = model_info.keys.find { |k| k.to_s.end_with?('.context_length') }
            result[:context_length] = model_info[ctx_key] if ctx_key

            result
          end

          def routing_model_whitelist
            value = Legion::LLM::Settings.value(:routing, :model_whitelist)
            value.is_a?(Array) ? value : nil
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'llm.discovery.ollama.routing_model_whitelist')
            nil
          end

          def routing_model_blacklist
            value = Legion::LLM::Settings.value(:routing, :model_blacklist)
            value.is_a?(Array) ? value : nil
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'llm.discovery.ollama.routing_model_blacklist')
            nil
          end

          def discovery_settings
            return {} unless Legion.const_defined?('Settings', false)

            Legion::LLM::Settings.config_value(llm_settings, :discovery, {})
          rescue StandardError => e
            handle_exception(e, level: :debug)
            {}
          end

          def providers_settings
            Legion::LLM::Settings.config_value(llm_settings, :providers, {})
          end

          def llm_settings
            Legion::LLM::Settings.current_settings
          end
        end
      end
    end
  end
end
