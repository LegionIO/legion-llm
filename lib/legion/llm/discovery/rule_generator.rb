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
          ollama: :local,
          mlx:    :local,
          vllm:   :fleet
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
                model_name = model.is_a?(Hash) ? (model[:name] || model['name']).to_s : model.to_s
                next if model_name.empty?

                capability = embedding_model?(provider, model_name) ? :embed : :chat
                priority = (TIER_WEIGHT[tier] || 80) - order
                rules << build_rule(provider, instance_id, model_name, capability, tier, priority)
                rules << build_rule(provider, instance_id, model_name, :stream, tier, priority) if capability == :chat
                order += 1
              end
            end
          end
          rules.sort_by { |r| -r[:priority] }
        end

        def embedding_model?(provider, model)
          begin
            adapter = Call::Registry.for(provider)
            if adapter.respond_to?(:provider, true)
              prov = adapter.send(:provider)
              caps = prov.class.respond_to?(:capabilities) ? prov.class.capabilities : nil
              return caps.embeddings?(model) if caps.respond_to?(:embeddings?)
            end
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'llm.discovery.rule_generator.embedding_model_check')
          end

          name = model.to_s.downcase
          EMBEDDING_PATTERNS.any? { |pat| name.include?(pat) }
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
      end
    end
  end
end
