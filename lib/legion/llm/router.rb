# frozen_string_literal: true

require_relative 'router/resolution'
require_relative 'router/rule'
require_relative 'router/health_tracker'

module Legion
  module LLM
    module Router
      class << self
        # Resolve an LLM routing intent to a tier/provider/model decision.
        #
        # @param intent   [Hash, nil] routing intent (capability, privacy, etc.)
        # @param tier     [Symbol, nil] explicit tier override — skips rule matching
        # @param model    [String, nil] explicit model override
        # @param provider [Symbol, nil] explicit provider override
        # @return [Resolution, nil]
        def resolve(intent: nil, tier: nil, model: nil, provider: nil)
          return explicit_resolution(tier, provider, model) if tier

          return nil unless routing_enabled? && intent

          merged = merge_defaults(intent)
          rules = load_rules
          candidates = select_candidates(rules, merged)
          best = pick_best(candidates)
          best&.to_resolution
        end

        def health_tracker
          @health_tracker ||= build_health_tracker
        end

        def routing_enabled?
          settings = routing_settings
          return false if settings.nil? || settings.empty?
          return false unless settings[:enabled]

          rules = settings[:rules]
          rules.is_a?(Array) && !rules.empty?
        end

        def reset!
          @health_tracker = nil
        end

        # Check whether a tier can be used right now.
        # :local — always available
        # :fleet — available when Legion::Transport is loaded
        # :cloud — always available
        def tier_available?(tier)
          return Legion.const_defined?('Transport') if tier.to_sym == :fleet

          true
        end

        private

        def explicit_resolution(tier, provider, model)
          resolved_provider = provider ? provider.to_sym : default_provider_for_tier(tier)
          resolved_model = model || default_model_for_tier(tier)

          Resolution.new(
            tier:     tier,
            provider: resolved_provider,
            model:    resolved_model,
            rule:     'explicit'
          )
        end

        def merge_defaults(intent)
          defaults = (routing_settings[:default_intent] || {})
                     .transform_keys(&:to_sym)
                     .transform_values { |v| v.respond_to?(:to_sym) ? v.to_sym : v }

          normalized_intent = intent
                              .transform_keys(&:to_sym)
                              .transform_values { |v| v.respond_to?(:to_sym) ? v.to_sym : v }

          defaults.merge(normalized_intent)
        end

        def load_rules
          raw = routing_settings[:rules] || []
          raw.map { |h| Rule.from_hash(h.transform_keys(&:to_sym)) }
        end

        def select_candidates(rules, intent)
          # 1. Collect constraints from constraint rules that match the intent
          constraints = rules
                        .select { |r| r.constraint && r.matches_intent?(intent) }
                        .map(&:constraint)

          # 2. Filter by intent match
          matched = rules.select { |r| r.matches_intent?(intent) }

          # 3. Filter by schedule
          scheduled = matched.select(&:within_schedule?)

          # 4. Reject rules excluded by active constraints
          unconstrained = scheduled.reject { |r| excluded_by_constraint?(r, constraints) }

          # 5. Filter by tier availability
          unconstrained.select { |r| tier_available?(r.target[:tier] || r.target['tier']) }
        end

        def excluded_by_constraint?(rule, constraints)
          return false if constraints.empty?

          tier = (rule.target[:tier] || rule.target['tier'])&.to_sym

          constraints.any? do |c|
            c.to_s == 'never_cloud' && tier == :cloud
          end
        end

        def pick_best(candidates)
          return nil if candidates.empty?

          candidates.max_by { |r| effective_priority(r) }
        end

        def effective_priority(rule)
          provider   = (rule.target[:provider] || rule.target['provider'])&.to_sym
          cost_bonus = (1.0 - rule.cost_multiplier) * 10
          rule.priority + health_tracker.adjustment(provider) + cost_bonus
        end

        def routing_settings
          llm = Legion::Settings[:llm]
          return {} unless llm.is_a?(Hash)

          routing = llm[:routing] || llm['routing'] || {}
          routing.transform_keys(&:to_sym)
        end

        def build_health_tracker
          settings = routing_settings
          cb       = (settings[:circuit_breaker] || {}).transform_keys(&:to_sym)

          HealthTracker.new(
            window_seconds:    settings.fetch(:window_seconds, 300),
            failure_threshold: cb.fetch(:failure_threshold, 3),
            cooldown_seconds:  cb.fetch(:cooldown_seconds, 60)
          )
        end

        def default_provider_for_tier(tier)
          if tier.to_sym == :cloud
            default = routing_settings[:default_provider]
            default ? default.to_sym : :bedrock
          else
            :ollama
          end
        end

        def default_model_for_tier(tier)
          case tier.to_sym
          when :local
            ollama = Legion::Settings[:llm].dig(:providers, :ollama) || {}
            ollama[:default_model] || 'llama3'
          when :fleet then 'llama4:70b'
          when :cloud
            Legion::Settings[:llm][:default_model] || 'claude-sonnet-4-6'
          else 'llama3'
          end
        end
      end
    end
  end
end
