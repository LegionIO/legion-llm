# frozen_string_literal: true

module Legion
  module LLM
    module Router
      # The SOLE body-model hint decision (SSOT v3 §17.1 / D19). Given the
      # untrusted request-body model value and any trusted explicit model, it
      # returns one immutable Phase 1 BodyModelHintDecision. It never returns a
      # lane, substitute model, or alias; only a `honored` decision carries a
      # model constraint. PayloadBuilder/translators/executor may not
      # independently reinterpret body.model — they consume this decision.
      #
      # X-Legion-Model (the trusted channel) is intentionally EXEMPT from the
      # whitelist/blacklist lists: a nonblank trusted model always supersedes.
      module BodyModelHintPolicy
        extend Legion::Logging::Helper

        def self.call(body_model:, trusted_model:, settings_snapshot:)
          requested = normalize(body_model)
          generation = settings_snapshot.generation

          # 1. missing/blank body model → absent (requested_model carries nil).
          return decision(requested_model: nil, disposition: :absent, settings_generation: generation) if requested.nil?

          # 2. body + trusted explicit model → trusted wins, body is metadata only.
          unless normalize(trusted_model).nil?
            return decision(requested_model: requested, disposition: :superseded_by_explicit_model,
                            settings_generation: generation)
          end

          # 3. auto-routing alias → auto (you-pick intent, no constraint).
          return decision(requested_model: requested, disposition: :auto, settings_generation: generation) if auto_alias?(requested, settings_snapshot.auto_routing_model_aliases)

          # 4. body hints globally disabled → ignored.
          unless settings_snapshot.allow_body_routing_hints
            return decision(requested_model: requested, disposition: :ignored_disabled,
                            settings_generation: generation)
          end

          whitelist = settings_snapshot.body_model_hint_whitelist
          blacklist = settings_snapshot.body_model_hint_blacklist

          # 5. nonempty whitelist with no match → ignored_not_whitelisted.
          if !whitelist.empty? && substring_match(requested, whitelist).nil?
            return decision(requested_model: requested, disposition: :ignored_not_whitelisted,
                            settings_generation: generation)
          end

          # 6. any blacklist match → ignored_blacklisted (blacklist wins over whitelist).
          matched_black = substring_match(requested, blacklist)
          unless matched_black.nil?
            return decision(requested_model: requested, disposition: :ignored_blacklisted,
                            matched_blacklist: matched_black, matched_whitelist: substring_match(requested, whitelist),
                            settings_generation: generation)
          end

          # 7. honored → exact body model becomes the model constraint.
          decision(requested_model: requested, disposition: :honored, model_constraint: requested,
                   matched_whitelist: substring_match(requested, whitelist), settings_generation: generation)
        end

        def self.normalize(value)
          return nil if value.nil?

          trimmed = value.to_s.strip
          trimmed.empty? ? nil : trimmed
        end
        private_class_method :normalize

        # Auto aliases match by trimmed case-insensitive EXACT equality.
        def self.auto_alias?(model, aliases)
          down = model.downcase
          aliases.any? { |a| a.to_s.strip.downcase == down }
        end
        private_class_method :auto_alias?

        # Whitelist/blacklist use trimmed case-insensitive SUBSTRING matching
        # (never regex/glob). Returns the matched configured entry or nil.
        def self.substring_match(model, list)
          down = model.downcase
          list.find { |entry| down.include?(entry.to_s.strip.downcase) }
        end
        private_class_method :substring_match

        def self.decision(requested_model:, disposition:, settings_generation:,
                          model_constraint: nil, matched_whitelist: nil, matched_blacklist: nil)
          Legion::Extensions::Llm::Routing::BodyModelHintDecision.new(
            requested_model: requested_model, disposition: disposition, model_constraint: model_constraint,
            matched_whitelist: matched_whitelist, matched_blacklist: matched_blacklist,
            settings_generation: settings_generation
          )
        end
        private_class_method :decision
      end
    end
  end
end
