# frozen_string_literal: true

module Legion
  module LLM
    module Router
      class HealthTracker
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
            return :half_open if elapsed >= @cooldown_seconds
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
            circuit  = @circuits[provider]

            if circuit[:state] == :half_open
              circuit[:state]     = :open
              circuit[:opened_at] = Time.now
            else
              circuit[:failures] += 1
              if circuit[:failures] >= @failure_threshold
                circuit[:state]     = :open
                circuit[:opened_at] = Time.now
              end
            end
          end

          register_handler(:success) do |payload|
            provider = payload[:provider]
            ensure_circuit(provider)
            circuit             = @circuits[provider]
            circuit[:failures]  = 0
            circuit[:state]     = :closed
            circuit[:opened_at] = nil
          end

          register_handler(:latency) do |payload|
            provider = payload[:provider]
            @latency_window[provider] ||= []
            @latency_window[provider] << { value: payload[:value], at: payload[:at] }
          end
        end

        def ensure_circuit(provider)
          @circuits[provider] ||= { state: :closed, failures: 0, opened_at: nil }
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
          [LATENCY_PENALTY_STEP * multiplier, OPEN_PENALTY].max
        end
      end
    end
  end
end
