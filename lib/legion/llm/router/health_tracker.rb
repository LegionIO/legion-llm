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

        def initialize(window_seconds: 300, failure_threshold: 3, cooldown_seconds: 60, sweep_interval_seconds: 5)
          @window_seconds         = window_seconds
          @failure_threshold      = failure_threshold
          @cooldown_seconds       = cooldown_seconds
          @sweep_interval_seconds = sweep_interval_seconds

          @circuits        = {}
          @latency_window  = {}
          @handlers        = {}
          @denied_models   = {}
          @last_sweep_at   = Time.now
          @mutex           = Monitor.new

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

          log.debug "[llm][health_tracker] action=signal_received provider=#{provider} instance=#{instance || 'all'} signal=#{sym} value=#{value}"

          if instance
            payload = build_payload(provider: provider, instance: instance,
                                    key: instance_key(provider, instance),
                                    offering_id: offering_id, signal: sym,
                                    value: value, metadata: metadata)
            @mutex.synchronize { handler.call(payload) }
          else
            instances = known_instances(provider)
            if instances.empty?
              payload = build_payload(provider: provider, instance: nil,
                                      key: health_key(provider, offering_id),
                                      offering_id: offering_id, signal: sym,
                                      value: value, metadata: metadata)
              @mutex.synchronize { handler.call(payload) }
            else
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

        # Open a circuit immediately, bypassing the failure threshold.
        # Used when a single observation is conclusive (e.g., discovery unreachable).
        def trip_circuit(provider:, instance: nil, reason: nil)
          key = instance ? instance_key(provider, instance) : provider.to_s
          @mutex.synchronize do
            ensure_circuit(key)
            @circuits[key][:failures] = @failure_threshold.to_f
            do_transition_circuit!(key: key, to_state: :open)
          end
          log.warn("[llm][health_tracker] action=circuit_tripped provider=#{key} reason=#{reason}")
        end

        # Record that a model is denied for a provider+instance (e.g. AccessDenied).
        # Excluded from routing until restart or explicit clear.
        def deny_model(provider:, model:, instance: nil, reason: nil)
          key = instance ? instance_key(provider, instance) : provider.to_s
          @mutex.synchronize do
            @denied_models[key] ||= {}
            @denied_models[key][model.to_s] = { reason: reason, at: Time.now }
          end
          log.warn("[llm][health_tracker] action=model_denied provider=#{key} model=#{model} reason=#{reason}")
          write_deny_to_lane(key: key, model: model)
        end

        # Check if a model is denied for a provider+instance.
        def model_denied?(provider:, model:, instance: nil)
          key = instance ? instance_key(provider, instance) : provider.to_s
          @mutex.synchronize do
            !@denied_models.dig(key, model.to_s).nil?
          end
        end

        # List all denied models (for diagnostics).
        def denied_models
          @mutex.synchronize { @denied_models.dup }
        end

        # Clear denied models for a provider (or all if no args).
        def clear_denied(provider: nil, instance: nil)
          @mutex.synchronize do
            if provider
              key = instance ? instance_key(provider, instance) : provider.to_s
              @denied_models.delete(key)
            else
              @denied_models.clear
            end
          end
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
            @denied_models.clear
          end
        end

        # Advance any :open circuits past their cooldown to :half_open and write
        # the updated health to Inventory lanes. This decouples the open→half_open
        # transition from inbound traffic — without it, an excluded lane never
        # receives reports so circuit_state_for_key never fires, and the circuit
        # stays permanently :open (half-open probe starvation).
        #
        # Called by Router.request_lane on every selection so eligible circuits
        # are already advanced before the soft filter runs. Throttled by
        # sweep_interval_seconds to avoid per-request overhead under high load.
        def sweep_circuits!
          now = Time.now
          return if (now - @last_sweep_at) < @sweep_interval_seconds

          @last_sweep_at = now
          @mutex.synchronize do
            @circuits.each do |key, circuit|
              next unless circuit[:state] == :open
              next unless circuit[:opened_at]
              next unless (now - circuit[:opened_at]) >= @cooldown_seconds

              do_transition_circuit!(key: key, to_state: :half_open)
              log.info("[llm][health_tracker] action=sweep_half_open provider=#{key} cooldown_elapsed_s=#{(now - circuit[:opened_at]).round}")
            end
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true,
                              operation: 'health_tracker.sweep_circuits!')
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

        def circuit_state_for_key(key)
          circuit = @circuits[key]
          return :closed if circuit.nil?

          if circuit[:state] == :open
            elapsed = Time.now - circuit[:opened_at]
            if elapsed >= @cooldown_seconds
              # Persist the open->half_open transition and log it ONCE. Without
              # persisting, every read recomputed :half_open and re-logged the
              # transition (flooding logs, since circuit_state is read for many
              # candidates per request) and let every concurrent request probe at
              # once. @mutex is a reentrant Monitor, so this is safe whether or not
              # the caller already holds the lock (e.g. the :error handler).
              @mutex.synchronize do
                entry = @circuits[key]
                if entry && entry[:state] == :open
                  do_transition_circuit!(key: key, to_state: :half_open)
                  log.info("[llm][health_tracker] action=circuit_state_change from=open to=half_open provider=#{key} cooldown_elapsed_s=#{elapsed.round}")
                end
              end
              return :half_open
            end
          end

          circuit[:state]
        end

        def register_default_handlers
          register_handler(:error) do |payload|
            key = payload[:provider]
            ensure_circuit(key)
            circuit = @circuits[key]
            increment = [payload[:value].to_f, 1.0].max

            if circuit_state_for_key(key) == :half_open
              do_transition_circuit!(key: key, to_state: :open)
              log.warn("[llm][health_tracker] action=circuit_state_change from=half_open to=open provider=#{key} reason=error_during_probe")
            elsif circuit[:state] == :open
              circuit[:failures] += increment
              log.debug "[llm][health_tracker] action=error_recorded provider=#{key} failures=#{circuit[:failures]} state=already_open"
            else
              circuit[:failures] += increment
              log.debug "[llm][health_tracker] action=error_recorded provider=#{key} failures=#{circuit[:failures]} threshold=#{@failure_threshold}"
              if circuit[:failures] >= @failure_threshold
                do_transition_circuit!(key: key, to_state: :open)
                log.warn("[llm][health_tracker] action=circuit_state_change from=closed to=open provider=#{key} failures=#{circuit[:failures]} threshold=#{@failure_threshold}")
              end
            end
          end

          register_handler(:success) do |payload|
            key = payload[:provider]
            ensure_circuit(key)
            prev_state = circuit_state_for_key(key)
            do_transition_circuit!(key: key, to_state: :closed)
            log.info("[llm][health_tracker] action=circuit_state_change from=#{prev_state} to=closed provider=#{key}") if prev_state != :closed
          end

          register_handler(:quality_failure) do |payload|
            key = payload[:provider]
            log.debug "[llm][health_tracker] action=quality_failure_received provider=#{key}"
          end

          register_handler(:latency) do |payload|
            key = payload[:provider]
            @latency_window[key] ||= []
            @latency_window[key] << { value: payload[:value], at: payload[:at] }
            log.debug "[llm][health_tracker] action=latency_recorded provider=#{key} value_ms=#{payload[:value]}"
          end
        end

        def ensure_circuit(key)
          @circuits[key] ||= { state: :closed, failures: 0.0, opened_at: nil }
        end

        # Mutates circuit state for key and propagates to all matching Inventory lanes.
        # Always called inside @mutex.synchronize.
        def do_transition_circuit!(key:, to_state:)
          ensure_circuit(key)
          @circuits[key][:state] = to_state
          case to_state
          when :open
            @circuits[key][:opened_at] = Time.now
          when :closed
            @circuits[key][:opened_at] = nil
            @circuits[key][:failures]  = 0
            # :half_open preserves opened_at (original open timestamp) and failures for diagnostics
          end
          write_health_to_lanes(key: key, state: to_state)
        end

        # Maps a circuit state symbol to the health adjustment integer for lane storage.
        # opus L5: was an orphan call in earlier draft — private helper, used by write_health_to_lanes.
        def circuit_adjustment_for(state:, **)
          case state
          when :half_open then OPEN_PENALTY / 2
          when :open      then OPEN_PENALTY
          else                 0
          end
        end

        # G7 / sonnet G7: clamp negative TTLs at zero.
        def lane_ttl(lane:, **)
          return nil unless lane[:expires_at]

          [lane[:expires_at] - Time.now.to_f, 0.0].max
        end

        # Parses "provider/instance" key into [provider_sym, instance_sym].
        # Returns [key_as_sym, nil] for provider-only keys.
        def parse_key(key)
          s = key.to_s
          idx = s.index('/')
          return [s.to_sym, nil] unless idx

          [s[0, idx].to_sym, s[(idx + 1)..].to_sym]
        end

        # Writes the derived health block onto every Inventory lane matching (provider, instance).
        # Called on every circuit state transition (G17 / M6: settings read once per write_lane call).
        def write_health_to_lanes(key:, state:, **)
          provider, instance = parse_key(key)
          new_health = {
            circuit_state: state,
            denied:        false,
            available:     state != :open,
            adjustment:    circuit_adjustment_for(state: state)
          }.freeze

          Legion::LLM::Inventory.lanes_for(provider: provider, instance: instance).each do |lane|
            Legion::LLM::Inventory.write_lane(
              lane:   lane,
              ttl:    lane_ttl(lane: lane),
              health: new_health # explicit health: kwarg — overwrites existing (G21)
            )
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true,
                              operation: 'health_tracker.write_health_to_lanes',
                              key: key, state: state)
        end

        # Writes denied health onto the single matching (provider, instance, model) lane only.
        # G23: denied lanes get health_mult=-1.0 AND health[:denied]=true.
        def write_deny_to_lane(key:, model:, **)
          provider, instance = parse_key(key)
          # Find just the lanes matching this specific model.
          lanes = Legion::LLM::Inventory.lanes_for(provider: provider, instance: instance,
                                                   model: model.to_s)
          lanes.each do |lane|
            existing_health = lane[:health] || {}
            new_health = existing_health.merge(
              denied:        true,
              available:     false,
              circuit_state: existing_health.fetch(:circuit_state, :closed)
            ).freeze
            Legion::LLM::Inventory.write_lane(
              lane:   lane,
              ttl:    lane_ttl(lane: lane),
              health: new_health
            )
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true,
                              operation: 'health_tracker.write_deny_to_lane',
                              key: key, model: model)
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
          log.debug "[llm][health_tracker] action=latency_penalty_applied provider=#{key} avg_ms=#{avg.round} penalty=#{penalty}"
          penalty
        end
      end
    end
  end
end
