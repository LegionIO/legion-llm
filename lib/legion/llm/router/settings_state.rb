# frozen_string_literal: true

require 'concurrent/atomic/atomic_reference'
require 'legion/llm/router/settings_snapshot'

module Legion
  module LLM
    module Router
      # Atomically-managed singleton that holds the current validated
      # SettingsSnapshot generation.  A single on_reload callback updates it
      # without stalling request threads.
      module SettingsState
        extend Legion::Logging::Helper

        class << self
          # ---------------------------------------------------------------- #
          # Public API                                                         #
          # ---------------------------------------------------------------- #

          # Build generation 1 from the current Legion::Settings trees and
          # register exactly one on_reload callback.  Safe to call multiple
          # times; only the first call installs the callback (tracked by
          # @callback_registered).
          def install!
            snap = Legion::LLM::Router::SettingsSnapshot.build(
              generation:        1,
              llm_settings:      Legion::Settings[:llm],
              extension_settings: Legion::Settings[:extensions]
            )
            ref.set(snap)
            log.debug('[llm][settings_state] action=install generation=1')

            return if @callback_registered

            Legion::Settings.on_reload do
              reload!(
                llm_settings:      Legion::Settings[:llm],
                extension_settings: Legion::Settings[:extensions]
              )
            end
            @callback_registered = true
          end

          # Return the currently installed SettingsSnapshot.  Callers must
          # capture this once per logical request and not read it again mid-flight.
          # Lazily installs generation 1 if boot has not run (e.g. isolated unit
          # specs), so a snapshot is always available.
          def current
            snap = ref.get
            return snap unless snap.nil?

            install!
            ref.get
          end

          # Build the next snapshot atomically.  Increments generation only on
          # success.  If validation raises, logs at :warn, returns false, and
          # retains the prior generation unchanged.
          def reload!(llm_settings:, extension_settings:)
            prior = ref.get
            next_gen = (prior&.generation || 0) + 1

            next_snap = Legion::LLM::Router::SettingsSnapshot.build(
              generation:        next_gen,
              llm_settings:      llm_settings,
              extension_settings: extension_settings
            )
            ref.set(next_snap)
            log.debug("[llm][settings_state] action=reload generation=#{next_gen}")
            true
          rescue ArgumentError => e
            # SettingsSnapshot.build raises ArgumentError on invalid operator
            # configuration. Handle only that validation signal, retain the prior
            # generation, and return false. Any other StandardError is a
            # programming error and must propagate (never swallowed here).
            handle_exception(e, level: :warn, operation: 'llm.router.settings.reload')
            false
          end

          # RSpec-only.  Clears the current snapshot and callback registration
          # so specs start from a clean state.
          def reset!
            @ref = nil
            @callback_registered = false
          end

          # ---------------------------------------------------------------- #
          # Private                                                            #
          # ---------------------------------------------------------------- #

          private

          def ref
            @ref ||= Concurrent::AtomicReference.new(nil)
          end
        end
      end
    end
  end
end
