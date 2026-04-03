# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Router
      class HealthTracker
        include Legion::Logging::Helper

        OPEN_PENALTY         = -50
        LATENCY_THRESHOLD_MS = 5000
        LATENCY_PENALTY_STEP = -10

        def initialize(window_seconds: 300, failure_threshold: 3, cooldown_seconds: 60)
          @window_seconds    = window_seconds
          @failure_threshold = failure_threshold
          @cooldown_seconds  = cooldown_seconds

          @circuits       = {}
          @latency_window = {}
          @handlers       = {}
          @mutex          = Mutex.new

          register_default_handlers
        end

        # Register a custom handler for a signal type.
        def register_handler(signal, &block)
          @handlers[signal.to_sym] = block
        end

        # Thread-safe signal intake. Dispatches to the registered handler if one exists.
        def report(provider:, signal:, value:, metadata: {})
          sym     = signal.to_sym
          handler = @handlers[sym]
          return nil unless handler

          payload = { provider: provider, signal: sym, value: value, metadata: metadata, at: Time.now }
          @mutex.synchronize { handler.call(payload) }
        end

        # Returns total priority adjustment for a provider.
        # Combines circuit-breaker penalty and latency penalty.
        def adjustment(provider)
          circuit_adjustment(provider) + latency_adjustment(provider)
        end

        # Returns :closed, :open, or :half_open.
        def circuit_state(provider)
          circuit = @circuits[provider]
          return :closed if circuit.nil?

          if circuit[:state] == :open
            elapsed = Time.now - circuit[:opened_at]
            if elapsed >= @cooldown_seconds
              log.warn("Circuit open->half_open for provider=#{provider} (cooldown elapsed)")
              return :half_open
            end
          end

          circuit[:state]
        end

        # Clears circuit and latency data for a single provider.
        def reset(provider)
          @mutex.synchronize do
            @circuits.delete(provider)
            @latency_window.delete(provider)
          end
        end

        # Clears all state.
        def reset_all
          @mutex.synchronize do
            @circuits.clear
            @latency_window.clear
          end
        end

        private

        def register_default_handlers
          register_handler(:error) do |payload|
            provider = payload[:provider]
            ensure_circuit(provider)
            circuit = @circuits[provider]

            if circuit_state(provider) == :half_open
              circuit[:state]     = :open
              circuit[:opened_at] = Time.now
              log.warn("Circuit half_open->open for provider=#{provider} (error during probe)")
            else
              circuit[:failures] += 1.0
              if circuit[:failures] >= @failure_threshold
                circuit[:state]     = :open
                circuit[:opened_at] = Time.now
                log.warn("Circuit closed->open for provider=#{provider} (failures=#{circuit[:failures]})")
              end
            end
          end

          register_handler(:success) do |payload|
            provider = payload[:provider]
            ensure_circuit(provider)
            prev_state          = circuit_state(provider)
            circuit             = @circuits[provider]
            circuit[:failures]  = 0
            circuit[:state]     = :closed
            circuit[:opened_at] = nil
            log.warn("Circuit #{prev_state}->closed for provider=#{provider}") if prev_state != :closed
          end

          register_handler(:quality_failure) do |payload|
            provider = payload[:provider]
            ensure_circuit(provider)
            circuit = @circuits[provider]

            if circuit_state(provider) == :half_open
              circuit[:state]     = :open
              circuit[:opened_at] = Time.now
              log.warn("Circuit half_open->open for provider=#{provider} (quality failure during probe)")
            else
              circuit[:failures] += 0.5
              if circuit[:failures] >= @failure_threshold
                circuit[:state]     = :open
                circuit[:opened_at] = Time.now
                log.warn("Circuit closed->open for provider=#{provider} (quality failures=#{circuit[:failures]})")
              end
            end
          end

          register_handler(:latency) do |payload|
            provider = payload[:provider]
            @latency_window[provider] ||= []
            @latency_window[provider] << { value: payload[:value], at: payload[:at] }
          end
        end

        def ensure_circuit(provider)
          @circuits[provider] ||= { state: :closed, failures: 0.0, opened_at: nil }
        end

        def circuit_adjustment(provider)
          case circuit_state(provider)
          when :open      then OPEN_PENALTY
          when :half_open then OPEN_PENALTY / 2
          else                 0
          end
        end

        def latency_adjustment(provider)
          entries = @latency_window[provider]
          return 0 if entries.nil? || entries.empty?

          cutoff = Time.now - @window_seconds
          recent = entries.select { |e| e[:at] >= cutoff }

          # Prune stale entries in-place
          @latency_window[provider] = recent

          return 0 if recent.empty?

          avg = recent.sum { |e| e[:value] } / recent.size.to_f
          return 0 if avg <= LATENCY_THRESHOLD_MS

          multiplier = (avg / LATENCY_THRESHOLD_MS).floor
          penalty = [LATENCY_PENALTY_STEP * multiplier, OPEN_PENALTY].max
          log.debug("Latency penalty applied to provider=#{provider} avg_ms=#{avg.round} penalty=#{penalty}")
          penalty
        end
      end
    end
  end
end
