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

        DEFAULT_TIER_PRIORITY = %i[local direct fleet openai_compat cloud frontier].freeze
        CAPABILITY_ALIASES = {
          function_calling: :tools,
          functions:        :tools,
          tool:             :tools,
          tool_use:         :tools,
          stream:           :streaming,
          stream_chat:      :streaming
        }.freeze

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
                priority = tier_weight(model_tier) - order
                rules << build_rule(provider, instance_id, model_data, capability, model_tier, priority)
                if capability == :chat
                  rules << build_rule(provider, instance_id, model_data, :stream, model_tier, priority) if supports_streaming?(model_data)
                  rules << build_rule(provider, instance_id, model_data, :tools, model_tier, priority) if supports_tools?(model_data)
                end
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
            priority = tier_weight(tier)
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
          normalized = normalize_capabilities(caps)
          return normalized if normalized.any?

          nil
        end

        def supports_streaming?(model_data)
          capabilities = extract_capabilities(model_data)
          return true if capabilities.nil?

          capabilities.include?(:streaming)
        end

        def supports_tools?(model_data)
          capabilities = extract_capabilities(model_data)
          return false if capabilities.nil?

          capabilities.include?(:tools)
        end

        def normalize_capabilities(capabilities)
          Array(capabilities).compact.each_with_object([]) do |capability, normalized|
            next unless capability.respond_to?(:to_s)

            capability_sym = capability.to_s.downcase.strip.to_sym
            next if capability_sym.to_s.empty?

            normalized << capability_sym
            alias_sym = CAPABILITY_ALIASES[capability_sym]
            normalized << alias_sym if alias_sym
          end.uniq
        end

        def extract_field(model_data, field)
          return nil unless model_data.is_a?(Hash)

          model_data[field] || model_data[field.to_s]
        end

        def tier_weight(tier)
          tier_sym = tier.respond_to?(:to_sym) ? tier.to_sym : tier
          index = tier_priority.index(tier_sym)
          return 0 unless index

          (tier_priority.length - index) * 100
        end

        def tier_priority
          configured = Legion::LLM::Settings.value(:tier_order, default: nil)
          configured = Legion::LLM::Settings.value(:routing, :tier_order, default: nil) if blank_array?(configured)
          configured = Legion::LLM::Settings.value(:routing, :tier_priority, default: DEFAULT_TIER_PRIORITY) if blank_array?(configured)
          normalized = Array(configured).filter_map do |tier|
            tier.to_sym if tier.respond_to?(:to_sym)
          end
          normalized = DEFAULT_TIER_PRIORITY if normalized.empty?
          (normalized + DEFAULT_TIER_PRIORITY).uniq
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'rule_generator.tier_priority')
          DEFAULT_TIER_PRIORITY
        end

        def blank_array?(value)
          Array(value).empty?
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
