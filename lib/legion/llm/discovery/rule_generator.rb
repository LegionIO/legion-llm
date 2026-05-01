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
          whitelist = routing_model_whitelist
          blacklist = routing_model_blacklist

          rules = []
          discovered_instances.each do |provider, instances|
            next unless DISCOVERABLE_PROVIDERS.include?(provider.to_sym)
            next unless instances.is_a?(Hash)

            tier = TIER_MAP[provider.to_sym] || :local
            order = 0
            instances.each do |instance_id, data|
              models = data.is_a?(Hash) ? Array(data[:models]) : []
              models.each do |model|
                model_name = model.is_a?(Hash) ? (model[:name] || model['name']).to_s : model.to_s
                next if model_name.empty?
                next if filtered_out?(model_name, whitelist, blacklist)

                capability = embedding_model?(model_name) ? :embed : :chat
                priority = (TIER_WEIGHT[tier] || 80) - order
                rules << build_rule(provider, instance_id, model_name, capability, tier, priority)
                rules << build_rule(provider, instance_id, model_name, :stream, tier, priority) if capability == :chat
                order += 1
              end
            end
          end

          rules += generate_configured_provider_rules
          rules.sort_by { |r| -r[:priority] }
        end

        def embedding_model?(model)
          name = model.to_s.downcase
          EMBEDDING_PATTERNS.any? { |pat| name.include?(pat) }
        end

        def filtered_out?(model_name, whitelist, blacklist)
          name = model_name.to_s.downcase

          return true if whitelist&.any? && whitelist.none? { |pat| name.include?(pat.downcase) }

          return true if blacklist&.any? && blacklist.any? { |pat| name.include?(pat.downcase) }

          false
        end

        def generate_configured_provider_rules
          rules = []
          providers_config = Legion::LLM::Settings.value(:providers, default: {})
          return rules unless providers_config.is_a?(Hash)

          providers_config.each do |provider_name, config|
            next unless config.is_a?(Hash)
            next if config[:enabled] == false
            next if DISCOVERABLE_PROVIDERS.include?(provider_name.to_sym)

            tier = TIER_MAP[provider_name.to_sym]
            next unless tier

            default_model = config[:default_model]
            next unless default_model

            priority = TIER_WEIGHT[tier] || 40
            rules << build_rule(provider_name, :default, default_model, :chat, tier, priority)
            rules << build_rule(provider_name, :default, default_model, :stream, tier, priority)
          end

          rules
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.discovery.rule_generator.configured_providers')
          []
        end

        def build_rule(provider, instance, model, capability, tier, priority)
          {
            name:     "auto:#{provider}/#{instance}:#{model}:#{capability}",
            when:     { capability: capability },
            then:     { provider: provider.to_sym, instance: instance.to_sym,
                        model: model.to_s, tier: tier },
            priority: priority
          }
        end

        def routing_model_whitelist
          value = Legion::LLM::Settings.value(:routing, :model_whitelist)
          value.is_a?(Array) ? value : nil
        rescue StandardError
          nil
        end

        def routing_model_blacklist
          value = Legion::LLM::Settings.value(:routing, :model_blacklist)
          value.is_a?(Array) ? value : nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
