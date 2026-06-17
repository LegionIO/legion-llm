# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Router
      # Candidate selection, exclusion filters, and scoring extracted verbatim
      # from Router (NxN G14 3c). Mixed into the Router singleton via `extend`,
      # so every method keeps the same `self` (the Router module), the same
      # private visibility, the same access to Router constants (EFFORT_RANK),
      # to sibling helpers that stay on Router (tier_available?, tier_rank,
      # tier_priority, health_tracker, discovery_enabled?, required_capabilities,
      # normalize_capabilities, normalize_effort, external_tier?), and to the
      # @last_candidate_trace ivar. No behavior change.
      module Candidates
        private

        def effort_matching_bonus(rule, intent)
          effort = normalize_effort(intent&.dig(:effort))
          return 0 unless effort

          rule_effort = normalize_effort(
            rule.target[:effort] || rule.target['effort'] ||
              effort_for_tier(rule.target[:tier] || rule.target['tier'])
          )
          return 0 unless rule_effort

          distance = (EFFORT_RANK.fetch(rule_effort) - EFFORT_RANK.fetch(effort)).abs
          return 25 if distance.zero?
          return 10 if distance == 1

          0
        end

        def effort_for_tier(tier)
          case tier&.to_sym
          when :local, :direct then :low
          when :fleet then :moderate
          when :cloud then :high
          when :frontier then :reasoning
          end
        end

        def loaded_model_bonus(rule)
          loaded = rule.target[:loaded] || rule.target['loaded']
          loaded == true ? 5 : 0
        end

        def select_candidates(rules, intent, exclude: {}, estimated_tokens: nil)
          log.debug "[llm][router] action=select_candidates total_rules=#{rules.size} estimated_tokens=#{estimated_tokens}"
          trace = Hash.new(0)

          constraints = rules
                        .select { |r| r.constraint && r.matches_intent?(intent) }
                        .map(&:constraint)

          matched = rules.select { |r| r.matches_intent?(intent) }
          trace[:intent_mismatch] = rules.size - matched.size

          scheduled = matched.select(&:within_schedule?)
          trace[:schedule] = matched.size - scheduled.size

          capable = scheduled.select { |r| satisfies_required_capabilities?(r, intent) }
          trace[:missing_capability] = scheduled.size - capable.size

          unconstrained = capable.reject { |r| excluded_by_constraint?(r, constraints) }
          trace[:constraint] = capable.size - unconstrained.size

          discovered = unconstrained.reject { |r| excluded_by_discovery?(r) }
          trace[:discovery] = unconstrained.size - discovered.size

          memory_checked = discovered.reject { |r| excluded_by_memory?(r) }
          trace[:memory] = discovered.size - memory_checked.size

          context_fitted = if estimated_tokens&.positive?
                             memory_checked.reject { |r| excluded_by_context_window?(r, estimated_tokens) }
                           else
                             memory_checked
                           end
          trace[:context] = memory_checked.size - context_fitted.size

          normalized_exclude = exclude.is_a?(Hash) ? exclude : {}
          not_excluded = if normalized_exclude.empty?
                           context_fitted
                         else
                           context_fitted.reject { |r| excluded_by_caller?(r, normalized_exclude) }
                         end
          trace[:caller_exclude] = context_fitted.size - not_excluded.size

          not_denied = not_excluded.reject { |r| excluded_by_denial?(r) }
          trace[:denied] = not_excluded.size - not_denied.size

          final = not_denied.select { |r| tier_available?(r.target[:tier] || r.target['tier']) }
          trace[:tier_unavailable] = not_denied.size - final.size

          @last_candidate_trace = trace
          log.debug "[llm][router] action=select_candidates.done candidates_remaining=#{final.size} started_with=#{rules.size}"

          final
        end

        # Reject rules whose model's context_length is too small for the estimated token count.
        # Uses a 90% threshold to leave room for output tokens, matching the executor's compaction threshold.
        def excluded_by_context_window?(rule, estimated_tokens)
          context_length = rule.target[:context_length] || rule.target['context_length']
          return false unless context_length&.to_i&.positive?

          threshold = (context_length.to_i * 0.90).to_i
          if estimated_tokens > threshold
            log.debug "[llm][router] action=excluded_by_context_window model=#{rule.target[:model]} " \
                      "context_length=#{context_length} estimated_tokens=#{estimated_tokens} threshold=#{threshold}"
            return true
          end
          false
        end

        def satisfies_required_capabilities?(rule, intent)
          required = required_capabilities(intent)
          return true if required.empty?

          rule_capabilities = normalize_capabilities(rule.target[:model_capabilities] || rule.target['model_capabilities'] ||
                                                     rule.target[:capabilities] || rule.target['capabilities'])
          return false if rule_capabilities.empty?

          required.all? { |capability| rule_capabilities.include?(capability) }
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

        # Deliberate Discovery feeder read (NOT an Inventory.offerings consumer):
        # local-tier routing must gate on whether the model is actually pulled and
        # whether it fits in available RAM right now. Model byte-size and live
        # system memory are discovery-specific runtime facts that Inventory does
        # not (and should not) carry, so these gates read Discovery directly.
        def excluded_by_discovery?(rule)
          return false unless discovery_enabled?

          tier     = (rule.target[:tier] || rule.target['tier'])&.to_sym
          provider = (rule.target[:provider] || rule.target['provider'])&.to_sym
          model    = rule.target[:model] || rule.target['model']
          instance = rule.target[:instance] || rule.target['instance']

          return false unless tier == :local && model

          return true unless Discovery.model_available?(model, provider: provider, instance: instance)

          model_bytes = Discovery.model_size(model, provider: provider, instance: instance)
          available   = Discovery::System.available_memory_mb
          return false if model_bytes.nil? || available.nil?

          floor = Legion::Settings[:llm][:discovery][:memory_floor_mb]
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

        def excluded_by_denial?(rule)
          provider = (rule.target[:provider] || rule.target['provider'])&.to_sym
          model    = rule.target[:model] || rule.target['model']
          instance = rule.target[:instance] || rule.target['instance']
          return false unless provider && model

          health_tracker.model_denied?(provider: provider, model: model, instance: instance)
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

        def pick_best(candidates, intent: nil, hints: {})
          return nil if candidates.empty?

          candidates.max_by { |r| effective_priority(r, intent: intent, hints: hints) }
        end

        def effective_priority(rule, intent: nil, hints: {})
          provider = (rule.target[:provider] || rule.target['provider'])&.to_sym
          instance = (rule.target[:instance] || rule.target['instance'])&.to_sym
          offering_id = rule.target[:offering_id] || rule.target['offering_id']
          cost_bonus = (1.0 - rule.cost_multiplier) * 10
          tier_bonus = tier_priority_bonus(rule)
          hint_bonus = hint_matching_bonus(rule, hints)
          effort_bonus = effort_matching_bonus(rule, intent)
          loaded_bonus = loaded_model_bonus(rule)

          rule.priority +
            health_tracker.adjustment(provider, instance: instance, offering_id: offering_id) +
            cost_bonus + tier_bonus + hint_bonus + effort_bonus + loaded_bonus
        end

        # Score bonus when a rule's target matches caller-provided hints.
        # Each matching hint adds +50,000 to the priority, so header preferences
        # dominate normal scoring without converting preferences into constraints.
        # rule priority, health, or cost considerations.
        def hint_matching_bonus(rule, hints)
          return 0 if hints.nil? || hints.empty?

          target = rule.target
          target_provider = (target[:provider] || target['provider'])&.to_sym
          target_tier     = (target[:tier]     || target['tier'])&.to_sym
          target_model    = target[:model] || target['model']

          bonus = 0
          bonus += 50_000 if hints[:provider] && target_provider == hints[:provider].to_sym
          bonus += 50_000 if hints[:tier]     && target_tier     == hints[:tier].to_sym
          bonus += 50_000 if hints[:model]    && target_model && target_model == hints[:model].to_s
          bonus
        end

        def tier_priority_bonus(rule)
          tier = (rule.target[:tier] || rule.target['tier'])&.to_sym
          return 0 unless tier

          index = tier_rank[tier]
          return 0 unless index

          (tier_priority.size - index) * 100
        end
      end
    end
  end
end
