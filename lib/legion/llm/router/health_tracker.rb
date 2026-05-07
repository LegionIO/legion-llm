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
        # When +instance:+ is given, tracks under "provider/instance".
        # When +instance:+ is nil, tracks under "provider" (backward compat) or broadcasts
        # to all known instances of that provider.
        def report(provider:, signal:, value:, instance: nil, metadata: {}, offering_id: nil)
          sym     = signal.to_sym
          handler = @handlers[sym]
          return nil unless handler

          if instance
            # Instance-specific tracking
            payload = build_payload(provider: provider, instance: instance,
                                    key: instance_key(provider, instance),
                                    offering_id: offering_id, signal: sym,
                                    value: value, metadata: metadata)
            @mutex.synchronize { handler.call(payload) }
          else
            # Check if we have tracked instances for this provider; if so, broadcast
            instances = known_instances(provider)
            if instances.empty?
              # No instances tracked — use provider-level key (backward compat)
              payload = build_payload(provider: provider, instance: nil,
                                      key: health_key(provider, offering_id),
                                      offering_id: offering_id, signal: sym,
                                      value: value, metadata: metadata)
              @mutex.synchronize { handler.call(payload) }
            else
              # Broadcast to all known instances of this provider
              @mutex.synchronize do
                instances.each do |inst_key|
                  payload = build_payload(provider: provider, instance: nil,
                                          key: inst_key, offering_id: offering_id,
                                          signal: sym, value: value, metadata: metadata)
                  handler.call(payload)
                end
              end
            end
          end
        end

        # Returns total priority adjustment for a provider.
        # Combines circuit-breaker penalty and latency penalty.
        # When +instance:+ is given, returns that specific instance's adjustment.
        # When nil, returns the average across all known instances so one bad
        # node penalizes the provider proportionally instead of globally.
        def adjustment(provider, instance: nil, offering_id: nil)
          if instance
            key = instance_key(provider, instance)
            return circuit_adjustment(key) + latency_adjustment(key)
          end

          # Check for known instances — return average adjustment if any exist.
          instances = known_instances(provider)
          if instances.empty?
            # Backward compat: use provider-level or offering-level key
            key = health_key(provider, offering_id)
            key = provider if offering_id && !tracked?(key) && tracked?(provider)
            return circuit_adjustment(key) + latency_adjustment(key)
          end

          adjustments = instances.map { |k| circuit_adjustment(k) + latency_adjustment(k) }
          (adjustments.sum.to_f / adjustments.size).round
        end

        # Returns :closed, :open, or :half_open.
        # When +instance:+ is given, returns that specific instance's state.
        # When nil, returns the worst state across all known instances.
        def circuit_state(provider, instance: nil, offering_id: nil)
          return circuit_state_for_key(instance_key(provider, instance)) if instance

          # Check for known instances — return worst state if any exist
          instances = known_instances(provider)
          if instances.empty?
            # Backward compat: use provider-level or offering-level key
            key = health_key(provider, offering_id)
            key = provider if offering_id && !tracked?(key) && tracked?(provider)
            return circuit_state_for_key(key)
          end

          worst_circuit_state(instances)
        end

        # Clears circuit and latency data for a single provider.
        def reset(provider, instance: nil, offering_id: nil)
          key = instance ? instance_key(provider, instance) : health_key(provider, offering_id)
          @mutex.synchronize do
            @circuits.delete(key)
            @latency_window.delete(key)
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

        # Build key for provider/instance pair: "provider/instance"
        def instance_key(provider, instance)
          "#{provider}/#{instance}"
        end

        def health_key(provider, offering_id = nil)
          offering_id.nil? || offering_id.to_s.empty? ? provider : offering_id.to_s
        end

        def tracked?(key)
          @circuits.key?(key) || @latency_window.key?(key)
        end

        # Returns all tracked instance keys for a given provider (keys matching "provider/...")
        def known_instances(provider)
          prefix = "#{provider}/"
          all_keys = (@circuits.keys + @latency_window.keys).uniq
          all_keys.select { |k| k.is_a?(String) && k.start_with?(prefix) }
        end

        def build_payload(provider:, instance:, key:, offering_id:, signal:, value:, metadata:)
          {
            provider:    key,
            provider_id: provider,
            instance:    instance,
            offering_id: offering_id,
            signal:      signal,
            value:       value,
            metadata:    metadata,
            at:          Time.now
          }
        end

        # Returns the circuit state for a single key
        def circuit_state_for_key(key)
          circuit = @circuits[key]
          return :closed if circuit.nil?

          if circuit[:state] == :open
            elapsed = Time.now - circuit[:opened_at]
            if elapsed >= @cooldown_seconds
              log.warn("Circuit open->half_open for provider=#{key} (cooldown elapsed)")
              return :half_open
            end
          end

          circuit[:state]
        end

        # Returns the worst circuit state across multiple keys
        # Priority: :open > :half_open > :closed
        def worst_circuit_state(keys)
          states = keys.map { |k| circuit_state_for_key(k) }
          return :open if states.include?(:open)
          return :half_open if states.include?(:half_open)

          :closed
        end

        def register_default_handlers
          register_handler(:error) do |payload|
            key = payload[:provider]
            ensure_circuit(key)
            circuit = @circuits[key]

            if circuit_state_for_key(key) == :half_open
              circuit[:state]     = :open
              circuit[:opened_at] = Time.now
              log.warn("Circuit half_open->open for provider=#{key} (error during probe)")
            else
              circuit[:failures] += 1.0
              if circuit[:failures] >= @failure_threshold
                circuit[:state]     = :open
                circuit[:opened_at] = Time.now
                log.warn("Circuit closed->open for provider=#{key} (failures=#{circuit[:failures]})")
              end
            end
          end

          register_handler(:success) do |payload|
            key = payload[:provider]
            ensure_circuit(key)
            prev_state          = circuit_state_for_key(key)
            circuit             = @circuits[key]
            circuit[:failures]  = 0
            circuit[:state]     = :closed
            circuit[:opened_at] = nil
            log.warn("Circuit #{prev_state}->closed for provider=#{key}") if prev_state != :closed
          end

          register_handler(:quality_failure) do |payload|
            key = payload[:provider]
            ensure_circuit(key)
            circuit = @circuits[key]

            if circuit_state_for_key(key) == :half_open
              circuit[:state]     = :open
              circuit[:opened_at] = Time.now
              log.warn("Circuit half_open->open for provider=#{key} (quality failure during probe)")
            else
              circuit[:failures] += 0.5
              if circuit[:failures] >= @failure_threshold
                circuit[:state]     = :open
                circuit[:opened_at] = Time.now
                log.warn("Circuit closed->open for provider=#{key} (quality failures=#{circuit[:failures]})")
              end
            end
          end

          register_handler(:latency) do |payload|
            key = payload[:provider]
            @latency_window[key] ||= []
            @latency_window[key] << { value: payload[:value], at: payload[:at] }
          end
        end

        def ensure_circuit(key)
          @circuits[key] ||= { state: :closed, failures: 0.0, opened_at: nil }
        end

        def circuit_adjustment(key)
          case circuit_state_for_key(key)
          when :open      then OPEN_PENALTY
          when :half_open then OPEN_PENALTY / 2
          else                 0
          end
        end

        def latency_adjustment(key)
          entries = @latency_window[key]
          return 0 if entries.nil? || entries.empty?

          cutoff = Time.now - @window_seconds
          recent = entries.select { |e| e[:at] >= cutoff }

          # Prune stale entries in-place
          @latency_window[key] = recent

          return 0 if recent.empty?

          avg = recent.sum { |e| e[:value] } / recent.size.to_f
          return 0 if avg <= LATENCY_THRESHOLD_MS

          multiplier = (avg / LATENCY_THRESHOLD_MS).floor
          penalty = [LATENCY_PENALTY_STEP * multiplier, OPEN_PENALTY].max
          log.debug("Latency penalty applied to provider=#{key} avg_ms=#{avg.round} penalty=#{penalty}")
          penalty
        end
      end
    end
  end
end
