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

        KNOWN_MODEL_CAPABILITIES = {
          # OpenAI
          'gpt-4o'                              => { capabilities: %i[completion vision tools], context_length: 128_000 },
          'gpt-4o-mini'                         => { capabilities: %i[completion vision tools], context_length: 128_000 },
          'gpt-5'                               => { capabilities: %i[completion vision tools thinking], context_length: 1_000_000 },
          'o3'                                  => { capabilities: %i[completion tools thinking], context_length: 200_000 },
          'text-embedding-3-small'              => { capabilities: [:embedding], context_length: 8_191 },
          'text-embedding-3-large'              => { capabilities: [:embedding], context_length: 8_191 },
          # Anthropic
          'claude-sonnet-4-6'                   => { capabilities: %i[completion vision tools thinking], context_length: 200_000 },
          'claude-opus-4-6'                     => { capabilities: %i[completion vision tools thinking], context_length: 200_000 },
          'claude-haiku-4-5'                    => { capabilities: %i[completion vision tools], context_length: 200_000 },
          # Bedrock
          'us.anthropic.claude-sonnet-4-6-v1:0' => { capabilities: %i[completion vision tools thinking], context_length: 200_000 },
          'amazon.titan-embed-text-v2:0'        => { capabilities: [:embedding], context_length: 8_192 },
          # Gemini
          'gemini-2.5-flash'                    => { capabilities: %i[completion vision tools thinking], context_length: 1_000_000 },
          'gemini-2.5-pro'                      => { capabilities: %i[completion vision tools thinking], context_length: 1_000_000 }
        }.freeze

        module_function

        def generate(discovered_instances)
          global_whitelist = routing_model_whitelist
          global_blacklist = routing_model_blacklist

          rules = []
          discovered_instances.each do |provider, instances|
            next unless DISCOVERABLE_PROVIDERS.include?(provider.to_sym)
            next unless instances.is_a?(Hash)

            tier = TIER_MAP[provider.to_sym] || :local
            order = 0
            instances.each do |instance_id, data|
              models = data.is_a?(Hash) ? Array(data[:models]) : []
              inst_whitelist = data.is_a?(Hash) ? data[:model_whitelist] : nil
              inst_blacklist = data.is_a?(Hash) ? data[:model_blacklist] : nil

              models.each do |model|
                model_data = model.is_a?(Hash) ? model : { name: model.to_s }
                model_name = (model_data[:name] || model_data['name']).to_s
                next if model_name.empty?
                next if filtered_out?(model_name, inst_whitelist, inst_blacklist, global_whitelist, global_blacklist)

                capability = embedding_model?(model_data) ? :embed : :chat
                priority = (TIER_WEIGHT[tier] || 80) - order
                rules << build_rule(provider, instance_id, model_data, capability, tier, priority)
                rules << build_rule(provider, instance_id, model_data, :stream, tier, priority) if capability == :chat
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

        def filtered_out?(model_name, inst_whitelist, inst_blacklist, global_whitelist, global_blacklist)
          name = model_name.to_s.downcase
          whitelist = inst_whitelist || global_whitelist
          blacklist = inst_blacklist || global_blacklist

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

            known = KNOWN_MODEL_CAPABILITIES[default_model.to_s] || {}
            model_data = { name: default_model }.merge(known)
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
