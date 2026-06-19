# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inventory
      # Propagates settings changes (weight updates, policy changes) immediately into
      # the live inventory store so operators get instant effect without waiting for the
      # next refresher tick (G28 / SSOT plan D-D).
      #
      # NOTE: Legion::Settings.observe(...) is not yet available in this version of
      # legion-settings. attach! is a no-op until that API ships. The admin endpoint
      # (POST /api/llm/inventory/refresh) is the manual fallback (always available).
      module SettingsObserver
        extend Legion::Logging::Helper

        module_function

        # Wire on Legion::LLM.start.
        # No-op until legion-settings ships a settings observer API.
        def attach!(**)
          log.debug('[llm][inventory][settings_observer] attach! called (observer API not yet available; use admin endpoint for manual reweight)')
        end

        # Re-write all lanes for the affected provider (preserving health).
        # Called by the admin endpoint, and will be called by the settings observer
        # once that API is available.
        def handle_change(path:, **)
          return rewrite_all_lanes! if path.size <= 3

          provider = path[2]&.to_sym
          return unless provider

          Legion::LLM::Inventory.send(:invalidate_policy_sets!, provider: provider)
          Legion::LLM::Inventory.lanes_for(provider: provider).each do |lane_entry|
            ttl_remaining = ([lane_entry[:expires_at] - Time.now.to_f, 0].max if lane_entry[:expires_at])
            Legion::LLM::Inventory.write_lane(lane: lane_entry, ttl: ttl_remaining)
          end
          log.info("[llm][inventory][settings_observer] action=reweighted provider=#{provider}")
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true,
                              operation: 'inventory.settings_observer.handle_change', path: path)
        end

        # Re-write ALL lanes preserving health (used when tier_weights change).
        def rewrite_all_lanes!(**)
          Legion::LLM::Inventory.send(:invalidate_policy_sets!)
          Legion::LLM::Inventory.lanes.each do |lane_entry|
            ttl_remaining = ([lane_entry[:expires_at] - Time.now.to_f, 0].max if lane_entry[:expires_at])
            Legion::LLM::Inventory.write_lane(lane: lane_entry, ttl: ttl_remaining)
          end
          log.info('[llm][inventory][settings_observer] action=rewritten_all_lanes')
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true,
                              operation: 'inventory.settings_observer.rewrite_all')
        end
      end
    end
  end
end
