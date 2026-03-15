# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/health_tracker'

RSpec.describe Legion::LLM::Router::HealthTracker do
  subject(:tracker) { described_class.new(window_seconds: 300, failure_threshold: 3, cooldown_seconds: 60) }

  let(:provider) { :anthropic }

  # ─── 1. report stores signal; adjustment returns 0 for success-only ───────────

  describe '#report + #adjustment for success signals' do
    it 'returns 0 adjustment after success signals only' do
      tracker.report(provider: provider, signal: :success, value: nil)
      expect(tracker.adjustment(provider)).to eq(0)
    end
  end

  # ─── 2. report invokes the registered handler ─────────────────────────────────

  describe '#register_handler and #report' do
    it 'invokes a registered handler with the correct payload' do
      received = nil
      tracker.register_handler(:custom) { |payload| received = payload }
      tracker.report(provider: provider, signal: :custom, value: 42, metadata: { foo: :bar })

      expect(received).to include(
        provider: provider,
        signal:   :custom,
        value:    42,
        metadata: { foo: :bar }
      )
      expect(received[:at]).to be_a(Time)
    end
  end

  # ─── 3. report ignores unknown signals without error ─────────────────────────

  describe '#report with unknown signal' do
    it 'does not raise for an unregistered signal' do
      expect { tracker.report(provider: provider, signal: :no_such_signal, value: nil) }.not_to raise_error
    end

    it 'returns nil (no-op) for an unregistered signal' do
      result = tracker.report(provider: provider, signal: :no_such_signal, value: nil)
      expect(result).to be_nil
    end
  end

  # ─── 4. Circuit starts in :closed state ──────────────────────────────────────

  describe '#circuit_state' do
    it 'returns :closed for a provider with no recorded failures' do
      expect(tracker.circuit_state(provider)).to eq(:closed)
    end

    it 'returns :closed for a brand-new provider symbol' do
      expect(tracker.circuit_state(:never_seen)).to eq(:closed)
    end
  end

  # ─── 5. Circuit opens after failure_threshold consecutive errors ──────────────

  describe 'circuit opening' do
    it 'opens the circuit after failure_threshold errors' do
      3.times { tracker.report(provider: provider, signal: :error, value: nil) }
      expect(tracker.circuit_state(provider)).to eq(:open)
    end

    it 'does not open the circuit before failure_threshold is reached' do
      2.times { tracker.report(provider: provider, signal: :error, value: nil) }
      expect(tracker.circuit_state(provider)).to eq(:closed)
    end
  end

  # ─── 6. Open circuit returns -50 adjustment ──────────────────────────────────

  describe '#adjustment with open circuit' do
    it 'returns OPEN_PENALTY (-50) when circuit is open' do
      3.times { tracker.report(provider: provider, signal: :error, value: nil) }
      expect(tracker.adjustment(provider)).to eq(described_class::OPEN_PENALTY)
    end

    it 'returns -50 specifically' do
      3.times { tracker.report(provider: provider, signal: :error, value: nil) }
      expect(tracker.adjustment(provider)).to eq(-50)
    end
  end

  # ─── 7. Success resets failure count ─────────────────────────────────────────

  describe 'success resets failure count' do
    it 'resets failures to 0 and closes the circuit on success' do
      2.times { tracker.report(provider: provider, signal: :error, value: nil) }
      tracker.report(provider: provider, signal: :success, value: nil)
      expect(tracker.circuit_state(provider)).to eq(:closed)
    end

    it 'does not open circuit after success + more errors below threshold' do
      2.times { tracker.report(provider: provider, signal: :error, value: nil) }
      tracker.report(provider: provider, signal: :success, value: nil)
      2.times { tracker.report(provider: provider, signal: :error, value: nil) }
      expect(tracker.circuit_state(provider)).to eq(:closed)
    end
  end

  # ─── 8. Circuit transitions to :half_open after cooldown expires ──────────────

  describe 'half_open transition' do
    it 'returns :half_open when cooldown has elapsed since circuit opened' do
      3.times { tracker.report(provider: provider, signal: :error, value: nil) }
      expect(tracker.circuit_state(provider)).to eq(:open)

      # Fake the opened_at to be beyond cooldown
      circuit = tracker.instance_variable_get(:@circuits)[provider]
      circuit[:opened_at] = Time.now - 61

      expect(tracker.circuit_state(provider)).to eq(:half_open)
    end

    it 'stays :open when cooldown has NOT elapsed' do
      3.times { tracker.report(provider: provider, signal: :error, value: nil) }
      expect(tracker.circuit_state(provider)).to eq(:open)
    end
  end

  # ─── 9. Success during :half_open closes circuit ─────────────────────────────

  describe 'success during half_open' do
    before do
      3.times { tracker.report(provider: provider, signal: :error, value: nil) }
      # Simulate cooldown elapsed so circuit_state computes :half_open naturally
      circuit = tracker.instance_variable_get(:@circuits)[provider]
      circuit[:opened_at] = Time.now - 61
    end

    it 'closes the circuit on success' do
      expect(tracker.circuit_state(provider)).to eq(:half_open)
      tracker.report(provider: provider, signal: :success, value: nil)
      expect(tracker.circuit_state(provider)).to eq(:closed)
    end

    it 'returns 0 adjustment after success closes the half_open circuit' do
      tracker.report(provider: provider, signal: :success, value: nil)
      expect(tracker.adjustment(provider)).to eq(0)
    end
  end

  # ─── 10. Error during :half_open re-opens circuit ────────────────────────────

  describe 'error during half_open' do
    before do
      3.times { tracker.report(provider: provider, signal: :error, value: nil) }
      # Simulate cooldown elapsed so circuit_state computes :half_open naturally
      circuit = tracker.instance_variable_get(:@circuits)[provider]
      circuit[:opened_at] = Time.now - 61
    end

    it 're-opens the circuit on error' do
      expect(tracker.circuit_state(provider)).to eq(:half_open)
      tracker.report(provider: provider, signal: :error, value: nil)
      # opened_at is refreshed to now, so cooldown has NOT elapsed -> :open
      expect(tracker.circuit_state(provider)).to eq(:open)
    end

    it 'returns -50 adjustment after re-opening' do
      tracker.report(provider: provider, signal: :error, value: nil)
      expect(tracker.adjustment(provider)).to eq(-50)
    end
  end

  # ─── 11. Normal latency returns 0 adjustment ─────────────────────────────────

  describe '#adjustment with normal latency' do
    it 'returns 0 when latency is below threshold' do
      tracker.report(provider: provider, signal: :latency, value: 1000)
      expect(tracker.adjustment(provider)).to eq(0)
    end

    it 'returns 0 when latency equals threshold exactly' do
      tracker.report(provider: provider, signal: :latency, value: described_class::LATENCY_THRESHOLD_MS)
      expect(tracker.adjustment(provider)).to eq(0)
    end
  end

  # ─── 12. High latency returns negative adjustment ────────────────────────────

  describe '#adjustment with high latency' do
    it 'returns LATENCY_PENALTY_STEP * floor(avg/threshold) for high latency' do
      # avg = 10_000, threshold = 5_000 -> multiplier = 2 -> penalty = -10 * 2 = -20
      3.times { tracker.report(provider: provider, signal: :latency, value: 10_000) }
      expect(tracker.adjustment(provider)).to eq(-20)
    end

    it 'caps the latency penalty at OPEN_PENALTY (-50)' do
      # avg = 50_000, threshold = 5_000 -> multiplier = 10 -> uncapped = -100, capped = -50
      3.times { tracker.report(provider: provider, signal: :latency, value: 50_000) }
      expect(tracker.adjustment(provider)).to eq(-50)
    end

    it 'returns -10 for latency just above 5000 (multiplier 1)' do
      3.times { tracker.report(provider: provider, signal: :latency, value: 6000) }
      expect(tracker.adjustment(provider)).to eq(-10)
    end
  end

  # ─── 13. reset clears one provider ───────────────────────────────────────────

  describe '#reset' do
    it 'clears circuit state for the specified provider' do
      3.times { tracker.report(provider: provider, signal: :error, value: nil) }
      expect(tracker.circuit_state(provider)).to eq(:open)

      tracker.reset(provider)
      expect(tracker.circuit_state(provider)).to eq(:closed)
    end

    it 'does not affect other providers' do
      other = :openai
      3.times { tracker.report(provider: provider, signal: :error, value: nil) }
      tracker.report(provider: other, signal: :latency, value: 10_000)

      tracker.reset(provider)

      expect(tracker.circuit_state(provider)).to eq(:closed)
      # other provider's latency window intact
      expect(tracker.adjustment(other)).to eq(-20)
    end

    it 'clears latency window for the specified provider' do
      3.times { tracker.report(provider: provider, signal: :latency, value: 10_000) }
      tracker.reset(provider)
      expect(tracker.adjustment(provider)).to eq(0)
    end
  end

  # ─── 14. reset_all clears all providers ──────────────────────────────────────

  describe '#reset_all' do
    it 'clears all circuits and latency windows' do
      %i[anthropic openai bedrock].each do |p|
        3.times { tracker.report(provider: p, signal: :error, value: nil) }
        tracker.report(provider: p, signal: :latency, value: 20_000)
      end

      tracker.reset_all

      %i[anthropic openai bedrock].each do |p|
        expect(tracker.circuit_state(p)).to eq(:closed)
        expect(tracker.adjustment(p)).to eq(0)
      end
    end
  end

  # ─── 15. Stale latency entries beyond window are ignored ─────────────────────

  describe 'latency window pruning' do
    it 'ignores latency entries older than window_seconds' do
      # Use a short window tracker
      short_tracker = described_class.new(window_seconds: 10, failure_threshold: 3, cooldown_seconds: 60)

      # Inject stale entry directly
      stale_time = Time.now - 20
      short_tracker.instance_variable_get(:@latency_window)[provider] = [
        { value: 50_000, at: stale_time }
      ]

      # Recent entry is fine
      short_tracker.report(provider: provider, signal: :latency, value: 1000)

      expect(short_tracker.adjustment(provider)).to eq(0)
    end

    it 'uses only in-window entries for average calculation' do
      short_tracker = described_class.new(window_seconds: 10, failure_threshold: 3, cooldown_seconds: 60)

      stale_time = Time.now - 20
      window = short_tracker.instance_variable_get(:@latency_window)
      window[provider] = [{ value: 50_000, at: stale_time }]

      # Recent high-latency entry: avg = 10_000, multiplier = 2, penalty = -20
      short_tracker.report(provider: provider, signal: :latency, value: 10_000)

      expect(short_tracker.adjustment(provider)).to eq(-20)
    end
  end
end
