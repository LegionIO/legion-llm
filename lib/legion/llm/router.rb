# frozen_string_literal: true

require_relative 'router/resolution'
require_relative 'router/rule'
require_relative 'router/health_tracker'
require_relative 'router/escalation/chain'
require_relative 'router/gateway_interceptor'
require_relative 'discovery/ollama'
require_relative 'discovery/rule_generator'
require_relative 'discovery/system'
require_relative 'discovery/memory_gate'

require 'legion/logging/helper'
module Legion
  module LLM
    module Router
      extend Legion::Logging::Helper

      PROVIDER_TIER = { bedrock: :cloud, anthropic: :frontier, openai: :frontier,
                        gemini: :cloud, azure: :cloud, ollama: :local, vllm: :fleet }.freeze
      PROVIDER_ORDER = %i[ollama vllm bedrock azure gemini anthropic openai].freeze
      TIER_EXTERNAL = Set[:cloud, :frontier, :openai_compat].freeze

      OLLAMA_MODEL_PATTERN = %r{[:/]}

      @auto_rules = []
      @auto_rules_populated = false

      class << self
        def infer_provider_for_model(model)
          return nil if model.nil? || model.to_s.empty?

          model_s = model.to_s
          return :bedrock if model_s.start_with?('us.')
          return :openai if model_s.match?(/\Agpt-|\Ao[134]-/)
          return :anthropic if model_s.start_with?('claude-')
          return :gemini if model_s.start_with?('gemini-')
          return :ollama if model_s.match?(OLLAMA_MODEL_PATTERN)

          nil
        end

        # Resolve an LLM routing intent to a tier/provider/model decision.
        #
        # @param intent   [Hash, nil] routing intent (capability, privacy, etc.)
        # @param tier     [Symbol, nil] explicit tier override — skips rule matching
        # @param model    [String, nil] explicit model override
        # @param provider [Symbol, nil] explicit provider override
        # @return [Resolution, nil]
        def resolve(intent: nil, tier: nil, model: nil, provider: nil, exclude: {})
          log.debug "[llm][router] action=resolve.enter intent=#{intent} tier=#{tier} model=#{model} provider=#{provider}"
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
          log.debug "[llm][router] action=resolve_chain.enter intent=#{intent} tier=#{tier} max_escalations=#{max_escalations}"
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

          settings[:enabled] == true && auto_rules_populated?
        end

        def auto_rules_populated?
          @auto_rules_populated == true
        end

        def populate_auto_rules(discovered_instances)
          raw = Discovery::RuleGenerator.generate(discovered_instances)
          @auto_rules = raw.map { |h| Rule.from_hash(h.transform_keys(&:to_sym)) }
          @auto_rules_populated = true
          log.info("[llm][router] auto_rules_populated count=#{@auto_rules.size}")
        end

        def reset!
          @health_tracker = nil
          @auto_rules = []
          @auto_rules_populated = false
        end

        # Check whether a tier can be used right now.
        # :local          — always available
        # :direct         — always available (remote self-hosted instances)
        # :fleet          — available when Legion::Transport is loaded
        # :openai_compat  — available when gateways are configured
        # :cloud          — available unless privacy mode
        # :frontier       — available unless privacy mode
        def tier_available?(tier)
          sym = tier.to_sym
          if external_tier?(sym) && privacy_mode?
            log.debug "[llm][router] action=tier_available tier=#{sym} available=false reason=privacy_mode"
            return false
          end
          if sym == :fleet
            available = Legion.const_defined?('Transport', false)
            log.debug "[llm][router] action=tier_available tier=fleet available=#{available}"
            return available
          end
          if sym == :openai_compat
            available = openai_compat_available?
            log.debug "[llm][router] action=tier_available tier=openai_compat available=#{available}"
            return available
          end

          true
        end

        private

        def arbitrage_fallback(intent)
          return nil unless defined?(Arbitrage) && Arbitrage.enabled?

          capability = intent&.dig(:capability) || :moderate
          model = Arbitrage.cheapest_for(capability: capability)
          return nil unless model

          provider = infer_provider_for_model(model)
          return nil unless provider

          tier = PROVIDER_TIER.fetch(provider, :cloud)
          log.debug("Router: arbitrage fallback selected model=#{model} provider=#{provider} tier=#{tier}")
          Resolution.new(tier: tier, provider: provider, model: model, rule: 'arbitrage_fallback')
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
          manual = (routing_settings[:rules] || []).map do |h|
            h = h.transform_keys(&:to_sym)
            h[:priority] = (h[:priority] || 0) + 1000
            Rule.from_hash(h)
          end
          (manual + (@auto_rules || [])).sort_by { |r| -r.priority }
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

          # 4.55 Reject local-tier rules where model exceeds available memory
          memory_checked = discovered.reject { |r| excluded_by_memory?(r) }

          # 4.6 Reject rules matching caller-provided exclude list
          normalized_exclude = exclude.is_a?(Hash) ? exclude : {}
          not_excluded = if normalized_exclude.empty?
                           memory_checked
                         else
                           memory_checked.reject { |r| excluded_by_caller?(r, normalized_exclude) }
                         end

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
          instance = rule.target[:instance] || rule.target['instance']

          return false unless tier == :local && provider == :ollama && model

          return true unless Discovery::Ollama.model_available?(model)

          model_bytes = Discovery::Ollama.model_size(model, instance: instance)
          available   = Discovery::System.available_memory_mb
          return false if model_bytes.nil? || available.nil?

          floor = discovery_settings[:memory_floor_mb] || 2048
          model_mb = model_bytes / 1024 / 1024
          model_mb > (available - floor)
        end

        def excluded_by_memory?(rule)
          return false unless discovery_enabled?

          tier = (rule.target[:tier] || rule.target['tier'])&.to_sym
          return false unless tier == :local

          model = rule.target[:model] || rule.target['model']
          provider = rule.target[:provider] || rule.target['provider']
          instance = rule.target[:instance] || rule.target['instance']
          !Discovery::MemoryGate.allow?(provider: provider, instance: instance, model: model)
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'router.excluded_by_memory')
          false
        end

        def discovery_enabled?
          ds = discovery_settings
          Legion::LLM::Settings.config_value(ds, :enabled, true)
        end

        def discovery_settings
          discovery = Legion::LLM::Settings.value(:discovery, default: {})
          discovery.is_a?(Hash) ? discovery.transform_keys(&:to_sym) : {}
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.router.discovery_settings')
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
          Legion::LLM::Settings.enterprise_privacy?
        end

        def external_tier?(tier)
          TIER_EXTERNAL.include?(tier)
        end

        def openai_compat_available?
          !openai_compat_gateways.empty?
        end

        def openai_compat_gateways
          tiers = Legion::LLM::Settings.config_value(routing_settings, :tiers, {})
          oc = Legion::LLM::Settings.config_value(tiers, :openai_compat, {})
          oc = oc.transform_keys(&:to_sym) if oc.is_a?(Hash)
          gateways = Legion::LLM::Settings.config_value(oc, :gateways)
          return [] unless gateways.is_a?(Array)

          gateways.map { |g| g.is_a?(Hash) ? g.transform_keys(&:to_sym) : nil }.compact
        end

        def pick_best(candidates)
          return nil if candidates.empty?

          candidates.max_by { |r| effective_priority(r) }
        end

        def effective_priority(rule)
          provider = (rule.target[:provider] || rule.target['provider'])&.to_sym
          offering_id = rule.target[:offering_id] || rule.target['offering_id']
          cost_bonus = (1.0 - rule.cost_multiplier) * 10
          rule.priority + health_tracker.adjustment(provider, offering_id: offering_id) + cost_bonus
        end

        def routing_settings
          routing = Legion::LLM::Settings.value(:routing, default: {})
          return {} unless routing.is_a?(Hash)

          routing.transform_keys(&:to_sym)
        end

        def build_health_tracker
          settings = routing_settings
          health   = Legion::LLM::Settings.config_value(settings, :health, {})
          health   = health.transform_keys(&:to_sym) if health.is_a?(Hash)
          cb       = Legion::LLM::Settings.config_value(health, :circuit_breaker, {})
          cb       = cb.transform_keys(&:to_sym) if cb.is_a?(Hash)

          HealthTracker.new(
            window_seconds:    health.fetch(:window_seconds, 300),
            failure_threshold: cb.fetch(:failure_threshold, 3),
            cooldown_seconds:  cb.fetch(:cooldown_seconds, 60)
          )
        end

        def default_provider_for_tier(tier)
          case tier.to_sym
          when :local, :direct
            :ollama
          when :fleet
            vllm_config = Legion::LLM::Settings.config_value(providers_settings, :vllm)
            vllm_config.is_a?(Hash) && Legion::LLM::Settings.config_value(vllm_config, :enabled) ? :vllm : :ollama
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
          when :local, :direct
            ollama = Legion::LLM::Settings.config_value(providers_settings, :ollama, {})
            Legion::LLM::Settings.config_value(ollama, :default_model) || 'llama3'
          when :fleet
            vllm_config = Legion::LLM::Settings.config_value(providers_settings, :vllm, {})
            if Legion::LLM::Settings.config_value(vllm_config, :enabled)
              Legion::LLM::Settings.config_value(vllm_config, :default_model) || 'qwen3.6-27b'
            else
              ollama = Legion::LLM::Settings.config_value(providers_settings, :ollama, {})
              Legion::LLM::Settings.config_value(ollama, :default_model) || 'llama3'
            end
          when :openai_compat
            'gpt-4o'
          when :cloud
            default_settings_model || 'us.anthropic.claude-sonnet-4-6'
          when :frontier
            default_settings_model || 'claude-sonnet-4-6'
          else
            'llama3'
          end
        end

        def chain_from_defaults(model, provider, max)
          if provider || model || default_settings_provider || default_settings_model
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
          providers = providers_settings
          return [] unless providers.is_a?(Hash)

          PROVIDER_ORDER.filter_map do |pname|
            config = Legion::LLM::Settings.config_value(providers, pname)
            next unless config.is_a?(Hash) && Legion::LLM::Settings.config_value(config, :enabled)

            tier  = PROVIDER_TIER.fetch(pname, :cloud)
            model = Legion::LLM::Settings.config_value(config, :default_model)
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
          esc = Legion::LLM::Settings.config_value(settings, :escalation, {})
          esc = esc.transform_keys(&:to_sym) if esc.is_a?(Hash)
          Legion::LLM::Settings.config_value(esc, :max_attempts, 3)
        end

        def default_settings_model
          Legion::LLM::Settings.value(:default_model)
        end

        def default_settings_provider
          Legion::LLM::Settings.value(:default_provider)
        end

        def providers_settings
          Legion::LLM::Settings.provider_settings
        end
      end
    end
  end
end
