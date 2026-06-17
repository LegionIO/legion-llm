# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Router
      # Registry lookup helpers extracted verbatim from Router (NxN G14 3c).
      # Mixed into the Router singleton via `extend`, so every method keeps the
      # same `self` (the Router module), the same private visibility, and the
      # same lexical access to Router constants (PROVIDER_TIER, PROVIDER_ORDER),
      # Call::Registry, Resolution, log, and handle_exception. No behavior change.
      module RegistryLookup
        private

        def registry_tier_for_default_provider(provider)
          instances = begin
            Call::Registry.all_instances
          rescue StandardError => e
            log.debug "[llm][router] action=registry_tier_fallback error=#{e.class} message=#{e.message}"
            []
          end
          entry = instances.find { |i| i[:provider] == provider }
          return registry_tier(provider, entry[:metadata]) if entry

          PROVIDER_TIER.fetch(provider, :cloud)
        end

        # Determine tier for a provider: prefer registry metadata, fall back to PROVIDER_TIER constant.
        def registry_tier(provider, metadata = {})
          meta_tier = metadata[:tier] if metadata.is_a?(Hash)
          return meta_tier.to_sym if meta_tier

          PROVIDER_TIER.fetch(provider.to_sym, :cloud)
        end

        # Find first registered provider matching a given tier.
        def registry_provider_for_tier(tier)
          registry_entry_for_tier(tier)&.[](:provider)
        end

        # Find the first registered instance for a specific provider.
        # When +instance+ is given, prefers the entry whose :instance matches;
        # falls back to the first provider entry if no exact match is found.
        def registry_entry_for_provider(provider, instance: nil)
          instances = begin
            Call::Registry.all_instances
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'router.registry_entry_for_provider')
            []
          end
          provider_entries = instances.select { |entry| entry[:provider] == provider }
          return nil if provider_entries.empty?

          if instance
            provider_entries.find { |entry| entry[:instance] == instance } || provider_entries.first
          else
            provider_entries.first
          end
        end

        # Find a default model from registry for a given tier.
        # Tries adapter.offerings first, then metadata[:default_model].
        def registry_model_for_tier(tier)
          registry_default_model(registry_entry_for_tier(tier))
        end

        def registry_entry_for_tier(tier)
          instances = begin
            Call::Registry.all_instances
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'router.registry_entry_for_tier')
            []
          end

          PROVIDER_ORDER.each do |pname|
            entry = instances.find do |candidate|
              candidate[:provider] == pname && registry_tier(pname, candidate[:metadata]) == tier
            end
            return entry if entry
          end
          nil
        end

        # Extract a default model from a registry entry.
        # Checks metadata[:default_model], then adapter.offerings.
        def registry_default_model(entry)
          return nil unless entry

          metadata = entry[:metadata] || {}

          # Prefer explicit default_model in metadata
          dm = metadata[:default_model]
          return dm.to_s unless dm.nil? || dm.to_s.empty?

          # Try adapter offerings
          adapter = entry[:adapter]
          if adapter.respond_to?(:offerings)
            models = begin
              adapter.offerings
            rescue StandardError => e
              handle_exception(e, level: :debug, handled: true, operation: 'router.registry_default_model')
              []
            end
            first = models.first
            return first[:model] || first[:id] if first.is_a?(Hash) && (first[:model] || first[:id])
          end

          nil
        end

        def registry_resolution_metadata(entry)
          return {} unless entry

          metadata = entry[:metadata]
          metadata.is_a?(Hash) ? metadata.dup : {}
        end
      end
    end
  end
end
