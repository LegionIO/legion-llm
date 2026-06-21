# frozen_string_literal: true

require 'legion/logging/helper'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

module Legion
  module LLM
    module Inventory
      # TTL safety net for the live inventory store. Runs every 30s to evict any lane
      # whose expires_at has passed. This is a backstop for dead or crashed writer actors;
      # ScopedRefresher's write-then-delete-orphans pattern (G7) is the primary eviction path.
      # Static-catalog lanes (expires_at: nil) are never swept.
      #
      # Uses Inventory.expired_ids — never .send(:map) on the internal store (M3).
      class Sweeper
        include Legion::Logging::Helper

        SWEEP_INTERVAL = 30

        # Class-level entry point for direct invocation and spec use.
        def self.sweep!(**)
          new.send(:sweep!)
        end

        # Every actor interface — time (seconds between ticks).
        def time
          SWEEP_INTERVAL
        end

        # Every actor interface — called by the ::Every timer task.
        def manual(**)
          sweep!
        end

        private

        def sweep!
          ids = Legion::LLM::Inventory.expired_ids
          return if ids.empty?

          ids.each do |id|
            Legion::LLM::Inventory.delete_lane(id: id)
            log.info("[llm][inventory][sweeper] action=evict id=#{id}")
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'inventory.sweeper.sweep')
        end
      end
    end
  end
end
