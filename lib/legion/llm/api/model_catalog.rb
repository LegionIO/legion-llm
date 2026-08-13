# frozen_string_literal: true

require 'time'
require 'legion/logging/helper'

module Legion
  module LLM
    module API
      # Snapshot-only model catalog — §17.3 / D19 Copilot compatibility.
      #
      # .list  → frozen Array<Hash>  all models in the requested dialect
      # .fetch → frozen Hash or nil  single-model lookup; nil if not catalog-visible
      #
      # The catalog iterates the supplied snapshot once and NEVER calls
      # Router.next_lane, Ranker, or any callable.  Selection, lane weight,
      # and availability do not determine which models appear in the compat
      # view — only publication completion, supported-operation evidence, and
      # the §9.5 model policy (from settings_snapshot.model_policy_for) do.
      #
      # X-Legion-Model is intentionally exempt from the body-hint policy
      # evaluated here. This module handles only compat-view construction;
      # it does NOT re-apply D19 body-hint logic during GET /v1/models listing.
      module ModelCatalog
        include Legion::Logging::Helper
        extend  Legion::Logging::Helper

        VALID_DIALECTS     = %i[native openai anthropic].freeze
        OPENAI_OBJECT_TYPE = 'model'
        DEFAULT_OWNED_BY   = 'legion'
        private_constant :VALID_DIALECTS, :OPENAI_OBJECT_TYPE, :DEFAULT_OWNED_BY

        # ------------------------------------------------------------------ #
        # Public API                                                           #
        # ------------------------------------------------------------------ #

        # Returns a frozen Array<Hash> of model objects for the requested dialect.
        # dialect must be :native, :openai, or :anthropic; any other value raises
        # ArgumentError immediately.
        def self.list(snapshot:, settings_snapshot:, dialect:)
          validate_dialect!(dialect)
          log.debug("[llm][model_catalog] action=list dialect=#{dialect} " \
                    "snapshot_generation=#{snapshot.generation} " \
                    "settings_generation=#{settings_snapshot.generation}")
          case dialect
          when :native    then native_list(snapshot: snapshot)
          when :openai    then compat_list(snapshot: snapshot, settings_snapshot: settings_snapshot, dialect: :openai)
          when :anthropic then compat_list(snapshot: snapshot, settings_snapshot: settings_snapshot, dialect: :anthropic)
          end
        end

        # Returns the frozen dialect model object for +id+, or nil when:
        # - compat dialect: the model is not catalog-visible (body hint would be
        #   ignored or not whitelisted); auto-routing alias returns nil when the
        #   compat set is empty.
        # - native dialect: the id does not match any offering in the snapshot.
        def self.fetch(id:, snapshot:, settings_snapshot:, dialect:)
          validate_dialect!(dialect)
          list(snapshot: snapshot, settings_snapshot: settings_snapshot, dialect: dialect)
            .find { |m| m[:id] == id.to_s }
        end

        # ------------------------------------------------------------------ #
        # Private class methods                                                #
        # ------------------------------------------------------------------ #

        # Raise ArgumentError unless dialect is one of the three accepted symbols.
        def self.validate_dialect!(dialect)
          return if VALID_DIALECTS.include?(dialect)

          raise ArgumentError,
                "[llm][model_catalog] dialect must be one of #{VALID_DIALECTS.inspect}, " \
                "got #{dialect.inspect}"
        end
        private_class_method :validate_dialect!

        # Native: complete diagnostic view of every offering.
        # Every offering is included regardless of availability or policy so
        # operators can see exactly what the registry holds for diagnostics.
        # Enriched with the exact instance availability state and the publication
        # state from the three Phase 1 snapshot enumerators.
        def self.native_list(snapshot:)
          pub_by_key  = {}
          inst_by_key = {}
          snapshot.each_publication_status { |ps|   pub_by_key[ps.instance_key] = ps }
          snapshot.each_instance           { |inst| inst_by_key[inst.instance_key] = inst }

          entries = []
          snapshot.each_offering do |offering|
            ik = offering.instance_key
            entries << {
              id:                     offering.model.to_s,
              offering_id:            offering.offering_id.to_s,
              provider_family:        ik.provider_family.to_s,
              instance_id:            ik.instance_id.to_s,
              tier:                   offering.tier.to_s,
              supported_operations:   offering.supported_operations.map(&:to_s).freeze,
              unsupported_operations: offering.unsupported_operations.map(&:to_s).freeze,
              unknown_operations:     offering.unknown_operations.map(&:to_s).freeze,
              publication_state:      pub_by_key[ik]&.state&.to_s,
              availability_state:     inst_by_key[ik]&.availability&.state&.to_s, # rubocop:disable Style/SafeNavigationChainLength
              publication_source:     offering.publication_source.to_s,
              metadata:               offering.metadata
            }.freeze
          end
          entries.freeze
        end
        private_class_method :native_list

        # Compat: one entry per unique model that has at least one COMPLETE,
        # policy-permitted offering with a SUPPORTED operation.
        # Availability does NOT remove a model; an initializing claim with no
        # offering does NOT manufacture one (§17.3 behavioural rule).
        # Auto-routing aliases are appended only when the compat set is non-empty.
        def self.compat_list(snapshot:, settings_snapshot:, dialect:)
          # One-pass publication-status index (keyed by InstanceKey).
          pub_by_key = {}
          snapshot.each_publication_status { |ps| pub_by_key[ps.instance_key] = ps }

          # Collect eligible unique model identifiers; first-seen provider wins
          # for the owned_by field when the same model appears on multiple providers.
          seen = {} # model_id (String) => provider_family (String)
          snapshot.each_offering do |offering|
            model_id = offering.model.to_s
            next if seen.key?(model_id)

            ik = offering.instance_key
            ps = pub_by_key[ik]

            # Publication must be complete (not initializing).
            next unless ps&.state == :complete

            # Must advertise at least one supported operation.
            next if offering.supported_operations.empty?

            # §9.5 fail-closed whitelist-AND-blacklist model policy.
            next unless policy_permits?(offering: offering, settings_snapshot: settings_snapshot)

            seen[model_id] = ik.provider_family.to_s
          end

          # Build sorted, frozen model entries for deterministic list order.
          entries = seen.keys.sort.map do |model_id|
            format_compat_entry(id: model_id, owned_by: seen[model_id], dialect: dialect)
          end

          # Auto-routing aliases are appended ONLY when the compat set is non-empty.
          # Alias copilot-utility-small MUST return owned_by: 'legionio' via its
          # configured alias metadata.
          unless entries.empty?
            settings_snapshot.auto_routing_model_aliases.each do |alias_id|
              entries << format_alias_entry(
                alias_id:          alias_id,
                settings_snapshot: settings_snapshot,
                dialect:           dialect
              )
            end
          end

          entries.freeze
        end
        private_class_method :compat_list

        # §9.5 fail-closed primitive: case-insensitive literal substring matching.
        # A nonempty effective whitelist must match the offering model.
        # A matching blacklist always denies, including when the whitelist matched.
        def self.policy_permits?(offering:, settings_snapshot:)
          policy    = settings_snapshot.model_policy_for(offering: offering)
          whitelist = policy[:whitelist]
          blacklist = policy[:blacklist]
          model_lc  = offering.model.to_s.downcase

          # nonempty whitelist — at least one entry must match
          return false if whitelist.any? && whitelist.none? { |e| model_lc.include?(e.downcase) }

          # any blacklist match denies, even when whitelist also matched
          return false if blacklist.any? { |e| model_lc.include?(e.downcase) }

          true
        end
        private_class_method :policy_permits?

        # Build a real-model compat entry. No limits for real models because they
        # are deduplicated across providers and no single canonical context window
        # is available without selecting a specific lane.
        def self.format_compat_entry(id:, owned_by:, dialect:)
          case dialect
          when :openai    then format_openai_entry(id: id, owned_by: owned_by)
          when :anthropic then format_anthropic_entry(id: id)
          end
        end
        private_class_method :format_compat_entry

        # Build an auto-routing alias entry.
        # Limits: alias metadata[:context_window/:max_output_tokens] first, then
        # the registered llm.context_window / llm.max_output_tokens envelope.
        # No field comes from a selected, max-weight, or first lane.
        def self.format_alias_entry(alias_id:, settings_snapshot:, dialect:)
          meta     = settings_snapshot.auto_routing_model_alias_metadata[alias_id] || {}
          owned_by = meta[:owned_by] || DEFAULT_OWNED_BY
          created  = meta[:created]
          ctx      = meta[:context_window]    || Legion::Settings[:llm][:context_window]
          max_out  = meta[:max_output_tokens] || Legion::Settings[:llm][:max_output_tokens]
          limits   = { context_window: ctx, max_output_tokens: max_out }.freeze

          case dialect
          when :openai
            format_openai_entry(id: alias_id, owned_by: owned_by, created: created, limits: limits)
          when :anthropic
            format_anthropic_entry(id: alias_id, created: created, limits: limits)
          end
        end
        private_class_method :format_alias_entry

        # OpenAI model object shape: { id:, object: 'model', created:, owned_by: }
        # Limits are optional and included only for alias entries.
        def self.format_openai_entry(id:, owned_by:, created: nil, limits: nil)
          obj = {
            id:       id.to_s,
            object:   OPENAI_OBJECT_TYPE,
            created:  created || Time.now.to_i,
            owned_by: owned_by.to_s
          }
          if limits.is_a?(Hash)
            if limits[:context_window]
              obj[:context_window] = limits[:context_window]
              obj[:context_size]   = limits[:context_window]
            end
            obj[:max_output_tokens] = limits[:max_output_tokens] if limits[:max_output_tokens]
          end
          obj.freeze
        end
        private_class_method :format_openai_entry

        # Anthropic model object shape: { type: 'model', id:, display_name:, created_at: }
        # Limits are optional and translated to max_input_tokens / max_tokens.
        def self.format_anthropic_entry(id:, created: nil, limits: nil)
          ts  = created || Time.now.to_i
          obj = {
            type:         'model',
            id:           id.to_s,
            display_name: id.to_s,
            created_at:   Time.at(ts).utc.strftime('%Y-%m-%dT%H:%M:%SZ')
          }
          if limits.is_a?(Hash)
            obj[:max_input_tokens] = limits[:context_window]    if limits[:context_window]
            obj[:max_tokens]       = limits[:max_output_tokens] if limits[:max_output_tokens]
          end
          obj.freeze
        end
        private_class_method :format_anthropic_entry
      end
    end
  end
end
