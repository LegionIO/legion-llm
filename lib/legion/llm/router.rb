# frozen_string_literal: true

require_relative 'router/resolution'
require_relative 'router/rule'
require_relative 'router/health_tracker'
require_relative 'router/escalation/chain'
require_relative 'router/gateway_interceptor'
require_relative 'discovery/ollama'
require_relative 'discovery/system'

require 'legion/logging/helper'
module Legion
  module LLM
    module Router
      extend Legion::Logging::Helper

      PROVIDER_TIER = { bedrock: :cloud, anthropic: :frontier, openai: :frontier,
                        gemini: :cloud, azure: :cloud, ollama: :local }.freeze
      PROVIDER_ORDER = %i[ollama bedrock azure gemini anthropic openai].freeze

      class << self
        # Resolve an LLM routing intent to a tier/provider/model decision.
        #
        # @param intent   [Hash, nil] routing intent (capability, privacy, etc.)
        # @param tier     [Symbol, nil] explicit tier override — skips rule matching
        # @param model    [String, nil] explicit model override
        # @param provider [Symbol, nil] explicit provider override
        # @return [Resolution, nil]
        def resolve(intent: nil, tier: nil, model: nil, provider: nil, exclude: {})
          return explicit_resolution(tier, provider, model) if tier

          return nil unless routing_enabled? && intent

          merged = merge_defaults(intent)
          rules = load_rules
          candidates = select_candidates(rules, merged, exclude: exclude)
          best = pick_best(candidates)
          resolution = best&.to_resolution

          if resolution
            log.info("Routed to tier=#{resolution.tier} provider=#{resolution.provider} model=#{resolution.model} via rule='#{resolution.rule}'")
          else
            log.debug('Router: no rules matched, resolution is nil')
          end

          resolution || arbitrage_fallback(intent)
        end

        def resolve_chain(intent: nil, tier: nil, model: nil, provider: nil, max_escalations: nil, exclude: {})
          max = max_escalations || escalation_max_attempts
          return EscalationChain.new(resolutions: [explicit_resolution(tier, provider, model)], max_attempts: max) if tier
          return chain_from_defaults(model, provider, max) unless routing_enabled? && intent

          chain_from_intent(intent, max, exclude: exclude)
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
        # :local          — always available
        # :fleet          — available when Legion::Transport is loaded
        # :openai_compat  — available when gateways are configured
        # :cloud          — available unless privacy mode
        # :frontier       — available unless privacy mode
        def tier_available?(tier)
          sym = tier.to_sym
          return false if external_tier?(sym) && privacy_mode?
          return Legion.const_defined?('Transport', false) if sym == :fleet
          return openai_compat_available? if sym == :openai_compat

          true
        end

        private

        def arbitrage_fallback(intent)
          return nil unless defined?(Arbitrage) && Arbitrage.enabled?

          capability = intent&.dig(:capability) || :moderate
          model = Arbitrage.cheapest_for(capability: capability)
          return nil unless model

          provider = Arbitrage.cost_table[model] ? infer_provider(model) : nil
          log.debug("Router: arbitrage fallback selected model=#{model}")
          Resolution.new(tier: :cloud, provider: provider || :bedrock, model: model, rule: 'arbitrage_fallback')
        end

        def infer_provider(model)
          return :ollama if model.include?('llama')
          return :bedrock if model.start_with?('us.')
          return :openai if model.start_with?('gpt')
          return :google if model.start_with?('gemini')

          :anthropic if model.start_with?('claude')
        end

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

        def select_candidates(rules, intent, exclude: {})
          log.debug("Router: selecting candidates from #{rules.size} rules")

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

          # 4.5 Reject Ollama rules where model is not pulled or doesn't fit
          discovered = unconstrained.reject { |r| excluded_by_discovery?(r) }

          # 4.6 Reject rules matching caller-provided exclude list
          normalized_exclude = exclude.is_a?(Hash) ? exclude : {}
          not_excluded = normalized_exclude.empty? ? discovered : discovered.reject { |r| excluded_by_caller?(r, normalized_exclude) }

          # 5. Filter by tier availability
          final = not_excluded.select { |r| tier_available?(r.target[:tier] || r.target['tier']) }

          log.debug("Router: #{final.size} candidates after filtering (started with #{rules.size})")

          final
        end

        def excluded_by_constraint?(rule, constraints)
          return false if constraints.empty?

          tier = (rule.target[:tier] || rule.target['tier'])&.to_sym

          constraints.any? do |c|
            case c.to_s
            when 'never_external'
              external_tier?(tier)
            when 'never_cloud'
              %i[cloud frontier].include?(tier)
            else
              false
            end
          end
        end

        def excluded_by_discovery?(rule)
          return false unless discovery_enabled?

          tier     = (rule.target[:tier] || rule.target['tier'])&.to_sym
          provider = (rule.target[:provider] || rule.target['provider'])&.to_sym
          model    = rule.target[:model] || rule.target['model']

          return false unless tier == :local && provider == :ollama && model

          return true unless Discovery::Ollama.model_available?(model)

          model_bytes = Discovery::Ollama.model_size(model)
          available   = Discovery::System.available_memory_mb
          return false if model_bytes.nil? || available.nil?

          floor = discovery_settings[:memory_floor_mb] || 2048
          model_mb = model_bytes / 1024 / 1024
          model_mb > (available - floor)
        end

        def discovery_enabled?
          ds = discovery_settings
          ds.fetch(:enabled, true)
        end

        def discovery_settings
          llm = Legion::Settings[:llm]
          return {} unless llm.is_a?(Hash)

          (llm[:discovery] || {}).transform_keys(&:to_sym)
        rescue StandardError => e
          handle_exception(e, level: :warn)
          {}
        end

        def excluded_by_caller?(rule, exclude)
          return false if exclude.nil? || exclude.empty?

          target   = rule.target || {}
          provider = (target[:provider] || target['provider'])&.to_sym
          model    = target[:model]    || target['model']
          tier     = (target[:tier]    || target['tier'])&.to_sym

          return true if exclude[:provider] && provider == exclude[:provider].to_sym
          return true if exclude[:model]    && model    == exclude[:model]
          return true if exclude[:tier]     && tier     == exclude[:tier].to_sym

          false
        end

        def privacy_mode?
          if Legion.const_defined?('Settings', false) && Legion::Settings.respond_to?(:enterprise_privacy?)
            Legion::Settings.enterprise_privacy?
          else
            ENV['LEGION_ENTERPRISE_PRIVACY'] == 'true'
          end
        end

        def external_tier?(tier)
          %i[cloud frontier openai_compat].include?(tier)
        end

        def openai_compat_available?
          !openai_compat_gateways.empty?
        end

        def openai_compat_gateways
          tiers = routing_settings[:tiers] || {}
          oc = (tiers[:openai_compat] || {}).transform_keys(&:to_sym)
          gateways = oc[:gateways]
          return [] unless gateways.is_a?(Array)

          gateways.map { |g| g.is_a?(Hash) ? g.transform_keys(&:to_sym) : nil }.compact
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
          health   = (settings[:health] || {}).transform_keys(&:to_sym)
          cb       = (health[:circuit_breaker] || {}).transform_keys(&:to_sym)

          HealthTracker.new(
            window_seconds:    health.fetch(:window_seconds, 300),
            failure_threshold: cb.fetch(:failure_threshold, 3),
            cooldown_seconds:  cb.fetch(:cooldown_seconds, 60)
          )
        end

        def default_provider_for_tier(tier)
          case tier.to_sym
          when :local, :fleet
            :ollama
          when :openai_compat
            :openai
          when :cloud
            default = routing_settings[:default_provider]
            default ? default.to_sym : :bedrock
          when :frontier
            :anthropic
          else
            :bedrock
          end
        end

        def default_model_for_tier(tier)
          case tier.to_sym
          when :local
            ollama = Legion::Settings[:llm].dig(:providers, :ollama) || {}
            ollama[:default_model] || 'llama3'
          when :fleet
            'llama4:70b'
          when :openai_compat
            'gpt-4o'
          when :cloud
            Legion::Settings[:llm][:default_model] || 'us.anthropic.claude-sonnet-4-6'
          when :frontier
            Legion::Settings[:llm][:default_model] || 'claude-sonnet-4-6'
          else
            'llama3'
          end
        end

        def chain_from_defaults(model, provider, max)
          if provider || model
            p = (provider || default_settings_provider)&.to_sym
            res = Resolution.new(tier:     PROVIDER_TIER.fetch(p, :frontier),
                                 provider: p || :anthropic,
                                 model:    model || default_settings_model || 'claude-sonnet-4-6')
            return EscalationChain.new(resolutions: [res], max_attempts: max)
          end

          resolutions = enabled_provider_chain
          if resolutions.empty?
            p = default_settings_provider&.to_sym || :anthropic
            resolutions = [Resolution.new(tier:     PROVIDER_TIER.fetch(p, :frontier),
                                          provider: p,
                                          model:    default_settings_model || 'claude-sonnet-4-6')]
          end
          EscalationChain.new(resolutions: resolutions, max_attempts: max)
        end

        def enabled_provider_chain
          providers = Legion::Settings[:llm][:providers]
          return [] unless providers.is_a?(Hash)

          PROVIDER_ORDER.filter_map do |pname|
            config = providers[pname]
            next unless config.is_a?(Hash) && config[:enabled]

            tier  = PROVIDER_TIER.fetch(pname, :cloud)
            model = config[:default_model]
            next if model.nil? || model.to_s.empty?
            next unless tier_available?(tier)

            Resolution.new(tier: tier, provider: pname, model: model, rule: 'auto_chain')
          end
        end

        def chain_from_intent(intent, max, exclude: {})
          merged     = intent ? merge_defaults(intent) : {}
          rules      = load_rules
          candidates = select_candidates(rules, merged, exclude: exclude)
          sorted     = candidates.sort_by { |r| -effective_priority(r) }
          resolutions = sorted.map(&:to_resolution)
          resolutions = build_fallback_chain(sorted.first, sorted, resolutions) if sorted.first&.fallback
          resolutions = resolutions.uniq { |r| [r.provider, r.model] }
          resolutions = enabled_provider_chain if resolutions.empty?
          if resolutions.empty?
            p = default_settings_provider&.to_sym || :anthropic
            resolutions = [Resolution.new(tier:     PROVIDER_TIER.fetch(p, :frontier),
                                          provider: p,
                                          model:    default_settings_model || 'claude-sonnet-4-6')]
          end
          EscalationChain.new(resolutions: resolutions, max_attempts: max)
        end

        def build_fallback_chain(primary_rule, candidates, default_chain)
          chain = [primary_rule.to_resolution]
          current = primary_rule

          while current.fallback
            fallback_target = current.fallback
            if fallback_target.is_a?(Hash)
              fb = fallback_target.transform_keys(&:to_sym)
              fb_tier     = fb[:tier]&.to_sym || :frontier
              fb_provider = fb[:provider]&.to_sym || default_provider_for_tier(fb_tier)
              fb_model    = fb[:model] || default_model_for_tier(fb_tier)
              chain << Resolution.new(tier: fb_tier, provider: fb_provider, model: fb_model)
              break
            else
              next_rule = candidates.find { |r| r.name == fallback_target.to_s }
              break unless next_rule

              chain << next_rule.to_resolution
              current = next_rule
            end
          end

          remaining = default_chain.reject { |r| chain.any? { |c| c.provider == r.provider && c.model == r.model } }
          chain + remaining
        end

        def escalation_max_attempts
          settings = routing_settings
          esc = (settings[:escalation] || {}).transform_keys(&:to_sym)
          esc.fetch(:max_attempts, 3)
        end

        def default_settings_model
          llm = Legion::Settings[:llm]
          llm[:default_model] if llm.is_a?(Hash)
        end

        def default_settings_provider
          llm = Legion::Settings[:llm]
          llm[:default_provider] if llm.is_a?(Hash)
        end
      end
    end
  end
end
