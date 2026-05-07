# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Discovery
      module RuleGenerator
        extend Legion::Logging::Helper

        EMBEDDING_PATTERNS = %w[
          embed mxbai-embed nomic-embed bge- snowflake-arctic-embed
          text-embedding titan-embed
        ].freeze

        DISCOVERABLE_PROVIDERS = %i[ollama mlx vllm].freeze

        TIER_MAP = {
          ollama:    :local,
          mlx:       :local,
          vllm:      :fleet,
          openai:    :cloud,
          bedrock:   :cloud,
          azure:     :cloud,
          gemini:    :cloud,
          anthropic: :frontier
        }.freeze

        TIER_WEIGHT = { local: 100, fleet: 80, cloud: 60, frontier: 40 }.freeze

        module_function

        def generate(discovered_instances)
          rules = []
          discovered_instances.each do |provider, instances|
            next unless DISCOVERABLE_PROVIDERS.include?(provider.to_sym)
            next unless instances.is_a?(Hash)

            tier = TIER_MAP[provider.to_sym] || :local
            order = 0
            instances.each do |instance_id, data|
              models = data.is_a?(Hash) ? Array(data[:models]) : []

              models.each do |model|
                model_data = model.is_a?(Hash) ? model : { name: model.to_s }
                model_name = (model_data[:name] || model_data['name']).to_s
                next if model_name.empty?

                model_tier = extract_field(model_data, :tier)&.to_sym ||
                             extract_field(model_data, 'tier')&.to_sym ||
                             tier
                capability = embedding_model?(model_data) ? :embed : :chat
                priority = (TIER_WEIGHT[model_tier] || 80) - order
                rules << build_rule(provider, instance_id, model_data, capability, model_tier, priority)
                rules << build_rule(provider, instance_id, model_data, :stream, model_tier, priority) if capability == :chat
                order += 1
              end
            end
          end

          rules += generate_configured_provider_rules
          rules.sort_by { |r| -r[:priority] }
        end

        def embedding_model?(model_data)
          if model_data.is_a?(Hash)
            caps = model_data[:capabilities] || model_data['capabilities']
            return caps.any? { |c| c.to_s == 'embedding' } if caps.is_a?(Array) && caps.any?
          end

          # Fall back to name pattern matching when no capability data
          name = model_data.is_a?(Hash) ? (model_data[:name] || model_data['name']).to_s : model_data.to_s
          name = name.downcase
          EMBEDDING_PATTERNS.any? { |pat| name.include?(pat) }
        end

        def generate_configured_provider_rules
          rules = []
          providers_config = extension_providers
          return rules unless providers_config.is_a?(Hash)

          providers_config.each do |provider_name, config|
            next unless config.is_a?(Hash)
            next if config[:enabled] == false
            next if DISCOVERABLE_PROVIDERS.include?(provider_name.to_sym)

            tier = TIER_MAP[provider_name.to_sym]
            next unless tier

            default_model = config[:default_model]
            next unless default_model

            model_data = { name: default_model }
            priority = TIER_WEIGHT[tier] || 40
            rules << build_rule(provider_name, :default, model_data, :chat, tier, priority)
            rules << build_rule(provider_name, :default, model_data, :stream, tier, priority)
          end

          rules
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.discovery.rule_generator.configured_providers')
          []
        end

        def build_rule(provider, instance, model_data, capability, tier, priority)
          model_name = model_data.is_a?(Hash) ? (model_data[:name] || model_data['name']).to_s : model_data.to_s
          target = {
            provider:           provider.to_sym,
            instance:           instance.to_sym,
            model:              model_name,
            tier:               tier,
            model_capabilities: extract_capabilities(model_data),
            context_length:     extract_field(model_data, :context_length),
            parameter_count:    extract_field(model_data, :parameter_count)
          }.compact
          {
            name:     "auto:#{provider}/#{instance}:#{model_name}:#{capability}",
            when:     { capability: capability },
            then:     target,
            priority: priority
          }
        end

        def extract_capabilities(model_data)
          return nil unless model_data.is_a?(Hash)

          caps = model_data[:capabilities] || model_data['capabilities']
          return caps if caps.is_a?(Array) && caps.any?

          nil
        end

        def extract_field(model_data, field)
          return nil unless model_data.is_a?(Hash)

          model_data[field] || model_data[field.to_s]
        end

        def extension_providers
          ext = Legion::Settings[:extensions]
          return ext[:llm] if ext.is_a?(Hash) && ext[:llm].is_a?(Hash)

          {}
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'rule_generator.extension_providers')
          {}
        end
      end
    end
  end
end
