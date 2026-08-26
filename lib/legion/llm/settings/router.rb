# frozen_string_literal: true

module Legion
  module LLM
    module Settings
      # Default settings for the Legion::LLM::Routing namespace, matched to the
      # module nested path: a setting for Legion::LLM::Routing::Foo lives at
      # Settings::Router.foo. Each default is its own self.<key> method;
      # defaults aggregates them. Wired into Settings.default as routing: once
      # the settings.rb rewire lands.
      module Router
        extend Legion::Logging::Helper

        def self.body_model_hint_whitelist
          []
        end

        def self.body_model_hint_blacklist
          []
        end

        def self.model_passthrough_ids
          %w[copilot-utility-small]
        end

        def self.auto_routing_model_aliases
          %w[legionio auto copilot-utility-small]
        end

        def self.auto_routing_model_alias_metadata
          {
            'copilot-utility-small' => { owned_by: 'legionio' }
          }
        end

        # Tier selection order (highest-priority first). The Router's
        # self.tier_priority reads this key and symbolizes it; a value always
        # exists here so the read never needs a || fallback.
        def self.tier_priority
          %i[local direct fleet cloud frontier]
        end

        # Fleet dispatch master switch. fleet_enabled? reads this key with
        # `!= false` semantics (default-on); the default guarantees presence.
        def self.fleet_dispatch_enabled
          true
        end

        # Attempt budget: targets tried before EscalationExhausted. A trusted
        # X-Legion-Max-Attempts constraint overrides this per request.
        def self.max_attempts
          3
        end

        # Affinity strength (basis points, 0..10_000) applied to routing
        # affinities when computing preference_ppm.
        def self.affinity_strength_bps
          10_000
        end

        # Conservative framing overhead (tokens) added to the byte-bound input
        # estimate before the context filter compares against a lane's window.
        def self.input_framing_overhead_tokens
          1_024
        end

        # Fraction (parts-per-million) of a lane's context window the router
        # treats as usable in the context filter. 900_000 ppm = 90%.
        def self.context_headroom_ppm
          900_000
        end

        # Whether an untrusted request-body model may act as a routing hint.
        # Default-off: only trusted pins and honored hints steer selection.
        def self.allow_body_routing_hints
          false
        end

        def self.defaults
          {
            body_model_hint_whitelist:         body_model_hint_whitelist,
            body_model_hint_blacklist:         body_model_hint_blacklist,
            model_passthrough_ids:             model_passthrough_ids,
            auto_routing_model_aliases:        auto_routing_model_aliases,
            auto_routing_model_alias_metadata: auto_routing_model_alias_metadata,
            tier_priority:                     tier_priority,
            fleet_dispatch_enabled:            fleet_dispatch_enabled,
            max_attempts:                      max_attempts,
            affinity_strength_bps:             affinity_strength_bps,
            input_framing_overhead_tokens:     input_framing_overhead_tokens,
            context_headroom_ppm:              context_headroom_ppm,
            allow_body_routing_hints:          allow_body_routing_hints
          }
        end
      end
    end
  end
end
