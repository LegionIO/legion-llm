# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/settings_snapshot'
require 'legion/llm/router/settings_state'

RSpec.describe Legion::LLM::Router::SettingsState do
  before do
    described_class.reset!
    # Install fresh defaults into Legion::Settings so install! has valid data.
    Legion::Settings.loader.settings[:llm] ||= {}
    Legion::Settings.loader.settings[:llm][:routing] ||= Legion::LLM::Settings.routing_defaults
    Legion::Settings.loader.settings[:llm][:api]     ||= Legion::LLM::Settings::API.defaults
    Legion::Settings.loader.settings[:extensions]    ||= {}
    Legion::Settings.loader.settings[:extensions][:llm] ||= {}
  end

  # ------------------------------------------------------------------ #
  # install! and current                                                 #
  # ------------------------------------------------------------------ #

  describe '.install!' do
    it 'produces a non-nil current snapshot at generation 1' do
      described_class.install!
      snap = described_class.current
      expect(snap).to be_a(Legion::LLM::Router::SettingsSnapshot)
      expect(snap.generation).to eq(1)
    end

    it 'returns a frozen snapshot' do
      described_class.install!
      expect(described_class.current).to be_frozen
    end
  end

  describe '.current' do
    it 'lazily installs generation 1 when boot has not run' do
      described_class.reset!
      snap = described_class.current
      expect(snap).not_to be_nil
      expect(snap.generation).to eq(1)
    end
  end

  # ------------------------------------------------------------------ #
  # reload! — success                                                    #
  # ------------------------------------------------------------------ #

  describe '.reload!' do
    before { described_class.install! }

    it 'increments the generation on success' do
      described_class.reload!(
        llm_settings:      Legion::Settings[:llm],
        extension_settings: Legion::Settings[:extensions]
      )
      expect(described_class.current.generation).to eq(2)
    end

    it 'returns true on success' do
      result = described_class.reload!(
        llm_settings:      Legion::Settings[:llm],
        extension_settings: Legion::Settings[:extensions]
      )
      expect(result).to be(true)
    end

    it 'replaces the snapshot atomically' do
      old_snap = described_class.current
      described_class.reload!(
        llm_settings:      Legion::Settings[:llm],
        extension_settings: Legion::Settings[:extensions]
      )
      expect(described_class.current).not_to equal(old_snap)
    end

    it 'reflects a settings change after reload' do
      Legion::Settings.loader.settings[:llm][:routing][:max_attempts] = 7
      described_class.reload!(
        llm_settings:      Legion::Settings[:llm],
        extension_settings: Legion::Settings[:extensions]
      )
      expect(described_class.current.maximum_attempts).to eq(7)
    end
  end

  # ------------------------------------------------------------------ #
  # reload! — malformed input retains prior generation                  #
  # ------------------------------------------------------------------ #

  describe '.reload! with invalid settings' do
    before { described_class.install! }

    it 'returns false when settings are invalid' do
      Legion::Settings.loader.settings[:llm][:routing][:max_attempts] = 0 # invalid: must be positive
      result = described_class.reload!(
        llm_settings:      Legion::Settings[:llm],
        extension_settings: Legion::Settings[:extensions]
      )
      expect(result).to be(false)
    end

    it 'retains the prior generation when reload! fails' do
      prior_snap = described_class.current
      prior_gen  = prior_snap.generation

      Legion::Settings.loader.settings[:llm][:routing][:max_attempts] = 0
      described_class.reload!(
        llm_settings:      Legion::Settings[:llm],
        extension_settings: Legion::Settings[:extensions]
      )

      expect(described_class.current).to equal(prior_snap)
      expect(described_class.current.generation).to eq(prior_gen)
    end

    it 'retains prior snapshot when tier_weight is a float' do
      Legion::Settings.loader.settings[:llm][:routing][:tier_weights] = { direct: 1.5, local: 110, fleet: 110, cloud: 120, frontier: 150 }
      described_class.reload!(
        llm_settings:      Legion::Settings[:llm],
        extension_settings: Legion::Settings[:extensions]
      )
      expect(described_class.current.generation).to eq(1)
    end
  end

  # ------------------------------------------------------------------ #
  # on_reload callback integration                                       #
  # ------------------------------------------------------------------ #

  describe 'Legion::Settings.on_reload integration' do
    it 'increments the generation when settings are reloaded via the callback' do
      described_class.install!
      expect(described_class.current.generation).to eq(1)

      # Trigger the on_reload callback registered by install!
      # Simulate a valid reload by directly calling reload! as the callback does.
      described_class.reload!(
        llm_settings:      Legion::Settings[:llm],
        extension_settings: Legion::Settings[:extensions]
      )

      expect(described_class.current.generation).to eq(2)
    end
  end

  # ------------------------------------------------------------------ #
  # reset!                                                               #
  # ------------------------------------------------------------------ #

  describe '.reset!' do
    it 'clears the installed snapshot so the next current lazily reinstalls generation 1' do
      described_class.install!
      described_class.reload!(llm_settings: Legion::Settings[:llm], extension_settings: Legion::Settings[:extensions])
      described_class.reset!
      # After reset, current lazily reinstalls a fresh generation-1 snapshot.
      expect(described_class.current.generation).to eq(1)
    end

    it 'allows install! to be called again after reset' do
      described_class.install!
      described_class.reset!
      described_class.install!
      expect(described_class.current.generation).to eq(1)
    end
  end
end
