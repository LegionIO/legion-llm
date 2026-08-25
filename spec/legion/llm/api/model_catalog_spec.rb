# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/model_catalog'
require 'legion/llm/routing/settings_state'

RSpec.describe Legion::LLM::API::ModelCatalog, :ssot_v3 do
  subject(:catalog) { described_class }

  # Reset SettingsState so each example starts from a known snapshot.
  # Ensure extensions settings are seeded (not nil) so SettingsState.current
  # can call SettingsSnapshot.build successfully.
  before do
    Legion::LLM::Routing::SettingsState.reset!
    Legion::Settings.loader.settings[:extensions] ||= {}
    Legion::Settings.loader.settings[:extensions][:llm] ||= {}
  end

  after do
    # Remove any per-test policy mutations and re-initialize a clean state.
    ext_llm = Legion::Settings.loader.settings.dig(:extensions, :llm) || {}
    ext_llm.delete(:model_whitelist)
    ext_llm.delete(:model_blacklist)
    Legion::Settings.loader.settings[:llm][:routing][:auto_routing_model_aliases] =
      Legion::LLM::Settings.routing_defaults[:auto_routing_model_aliases]
    Legion::Settings.loader.settings[:llm][:routing][:auto_routing_model_alias_metadata] =
      Legion::LLM::Settings.routing_defaults[:auto_routing_model_alias_metadata]
    Legion::LLM::Routing::SettingsState.reset!
  end

  let(:settings_snapshot) { Legion::LLM::Routing::SettingsState.current }

  # ------------------------------------------------------------------ #
  # Helpers                                                              #
  # ------------------------------------------------------------------ #

  def activate_vllm_h200(model:, supported: %i[chat], unsupported: [])
    activate(
      provider_family: 'vllm', instance_id: 'h200',
      drafts: [offering_draft(model: model, tier: :local,
                              supported: supported, unsupported: unsupported)]
    )
    snapshot
  end

  def activate_ollama_local(model:, supported: %i[chat])
    activate(
      provider_family: 'ollama', instance_id: 'local',
      drafts: [offering_draft(model: model, tier: :local, supported: supported)]
    )
    snapshot
  end

  # ------------------------------------------------------------------ #
  # dialect validation                                                   #
  # ------------------------------------------------------------------ #

  describe 'dialect validation' do
    let(:empty_snap) { snapshot }

    it 'raises ArgumentError for list with an unknown dialect' do
      expect do
        catalog.list(snapshot: empty_snap, settings_snapshot: settings_snapshot, dialect: :grpc)
      end.to raise_error(ArgumentError, /grpc/)
    end

    it 'raises ArgumentError for fetch with an unknown dialect' do
      expect do
        catalog.fetch(id: 'gemma4', snapshot: empty_snap,
                      settings_snapshot: settings_snapshot, dialect: :graphql)
      end.to raise_error(ArgumentError, /graphql/)
    end

    it 'does not raise for :native dialect' do
      expect do
        catalog.list(snapshot: empty_snap, settings_snapshot: settings_snapshot, dialect: :native)
      end.not_to raise_error
    end

    it 'does not raise for :openai dialect' do
      expect do
        catalog.list(snapshot: empty_snap, settings_snapshot: settings_snapshot, dialect: :openai)
      end.not_to raise_error
    end

    it 'does not raise for :anthropic dialect' do
      expect do
        catalog.list(snapshot: empty_snap, settings_snapshot: settings_snapshot, dialect: :anthropic)
      end.not_to raise_error
    end
  end

  # ------------------------------------------------------------------ #
  # compat list — basic inclusion (:openai)                              #
  # ------------------------------------------------------------------ #

  describe '.list (openai dialect) — real supported model' do
    let(:snap) { activate_vllm_h200(model: 'gemma4', supported: %i[chat]) }

    it 'includes the real supported model by id' do
      list = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
      expect(list.map { |m| m[:id] }).to include('gemma4')
    end

    it 'returns a frozen Array' do
      result = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
      expect(result).to be_frozen
    end

    it 'each entry is a frozen Hash' do
      list = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
      list.each { |m| expect(m).to be_frozen }
    end

    it 'real model entry has the OpenAI model object shape' do
      list  = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
      entry = list.find { |m| m[:id] == 'gemma4' }
      expect(entry).to include(id: 'gemma4', object: 'model')
      expect(entry[:created]).to be_a(Integer)
      expect(entry[:owned_by]).to be_a(String)
    end
  end

  # ------------------------------------------------------------------ #
  # compat list — auto-routing aliases appended only when set non-empty  #
  # ------------------------------------------------------------------ #

  describe '.list (openai dialect) — alias behaviour' do
    context 'when the compat set is non-empty' do
      let(:snap) { activate_vllm_h200(model: 'gemma4') }

      it 'appends all configured auto-routing aliases' do
        list = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
        ids  = list.map { |m| m[:id] }
        settings_snapshot.auto_routing_model_aliases.each do |alias_id|
          expect(ids).to include(alias_id)
        end
      end

      it 'includes copilot-utility-small with owned_by: legionio' do
        list  = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
        entry = list.find { |m| m[:id] == 'copilot-utility-small' }
        expect(entry).not_to be_nil
        expect(entry[:owned_by]).to eq('legionio')
      end

      it 'copilot-utility-small has openai model object shape' do
        list  = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
        entry = list.find { |m| m[:id] == 'copilot-utility-small' }
        expect(entry).to include(id: 'copilot-utility-small', object: 'model')
      end
    end

    context 'when the compat set is empty (no activations)' do
      let(:snap) { snapshot }

      it 'returns an empty list' do
        result = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
        expect(result).to be_empty
      end

      it 'does not append auto-routing aliases' do
        result = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
        ids = result.map { |m| m[:id] }
        settings_snapshot.auto_routing_model_aliases.each do |alias_id|
          expect(ids).not_to include(alias_id)
        end
      end

      it 'does not include copilot-utility-small when compat set is empty' do
        result = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
        expect(result.map { |m| m[:id] }).not_to include('copilot-utility-small')
      end
    end
  end

  # ------------------------------------------------------------------ #
  # exclusion: no supported operation                                    #
  # ------------------------------------------------------------------ #

  describe 'exclusion — model with only unsupported operations' do
    let(:snap) do
      activate(
        provider_family: 'vllm', instance_id: 'h200',
        drafts: [offering_draft(model: 'embed-only', tier: :local,
                                supported: [], unsupported: %i[chat stream_chat])]
      )
      snapshot
    end

    it 'does not include the model in the openai compat list' do
      list = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
      expect(list.map { |m| m[:id] }).not_to include('embed-only')
    end

    it 'does not include the model in the anthropic compat list' do
      list = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :anthropic)
      expect(list.map { |m| m[:id] }).not_to include('embed-only')
    end
  end

  # ------------------------------------------------------------------ #
  # exclusion: initializing-only claim, no offerings                     #
  # ------------------------------------------------------------------ #

  describe 'exclusion — initializing claim with no offerings' do
    let(:snap) do
      claim_only(provider_family: 'vllm', instance_id: 'h200')
      snapshot
    end

    it 'produces an empty compat list (no model manufactured from a claim alone)' do
      list = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
      # aliases not appended when compat set empty, so ids list is empty
      expect(list.map { |m| m[:id] }.reject { |id| id.start_with?('legionio', 'auto', 'copilot') }).to be_empty
    end

    it 'compat list is entirely empty' do
      list = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
      expect(list).to be_empty
    end
  end

  # ------------------------------------------------------------------ #
  # dedup across two providers of the same model identifier              #
  # ------------------------------------------------------------------ #

  describe 'deduplication across providers' do
    let(:snap) do
      activate(
        provider_family: 'vllm', instance_id: 'h200',
        drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])]
      )
      activate(
        provider_family: 'ollama', instance_id: 'local',
        drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])]
      )
      snapshot
    end

    it 'lists gemma4 exactly once despite two eligible providers' do
      list  = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
      count = list.count { |m| m[:id] == 'gemma4' }
      expect(count).to eq(1)
    end
  end

  # ------------------------------------------------------------------ #
  # policy whitelist / blacklist                                         #
  # ------------------------------------------------------------------ #

  describe 'model policy — whitelist filters the compat view' do
    let(:snap) { activate_vllm_h200(model: 'gemma4') }

    it 'excludes gemma4 when a nonempty whitelist does not match it' do
      Legion::Settings.loader.settings[:extensions][:llm][:model_whitelist] = ['allowed-model']
      Legion::LLM::Routing::SettingsState.reset!
      ss   = Legion::LLM::Routing::SettingsState.current
      list = catalog.list(snapshot: snap, settings_snapshot: ss, dialect: :openai)
      expect(list.map { |m| m[:id] }).not_to include('gemma4')
    end

    it 'includes gemma4 when the whitelist matches (substring)' do
      Legion::Settings.loader.settings[:extensions][:llm][:model_whitelist] = ['gemma']
      Legion::LLM::Routing::SettingsState.reset!
      ss   = Legion::LLM::Routing::SettingsState.current
      list = catalog.list(snapshot: snap, settings_snapshot: ss, dialect: :openai)
      expect(list.map { |m| m[:id] }).to include('gemma4')
    end
  end

  describe 'model policy — blacklist filters the compat view' do
    let(:snap) { activate_vllm_h200(model: 'gemma4') }

    it 'excludes gemma4 when the blacklist contains a matching substring' do
      Legion::Settings.loader.settings[:extensions][:llm][:model_blacklist] = ['gemma']
      Legion::LLM::Routing::SettingsState.reset!
      ss   = Legion::LLM::Routing::SettingsState.current
      list = catalog.list(snapshot: snap, settings_snapshot: ss, dialect: :openai)
      expect(list.map { |m| m[:id] }).not_to include('gemma4')
    end

    it 'blacklist denies even when whitelist also matches' do
      Legion::Settings.loader.settings[:extensions][:llm][:model_whitelist] = ['gemma']
      Legion::Settings.loader.settings[:extensions][:llm][:model_blacklist] = ['gemma4']
      Legion::LLM::Routing::SettingsState.reset!
      ss   = Legion::LLM::Routing::SettingsState.current
      list = catalog.list(snapshot: snap, settings_snapshot: ss, dialect: :openai)
      expect(list.map { |m| m[:id] }).not_to include('gemma4')
    end
  end

  # ------------------------------------------------------------------ #
  # .fetch                                                               #
  # ------------------------------------------------------------------ #

  describe '.fetch' do
    context 'when the compat set is non-empty' do
      let(:snap) { activate_vllm_h200(model: 'gemma4') }

      it 'returns the 200-object for copilot-utility-small' do
        result = catalog.fetch(id: 'copilot-utility-small', snapshot: snap,
                               settings_snapshot: settings_snapshot, dialect: :openai)
        expect(result).not_to be_nil
        expect(result[:id]).to eq('copilot-utility-small')
        expect(result[:owned_by]).to eq('legionio')
      end

      it 'returns the model entry for a known eligible real model' do
        result = catalog.fetch(id: 'gemma4', snapshot: snap,
                               settings_snapshot: settings_snapshot, dialect: :openai)
        expect(result).not_to be_nil
        expect(result[:id]).to eq('gemma4')
        expect(result[:object]).to eq('model')
      end

      it 'returns nil for an id not in the compat list' do
        result = catalog.fetch(id: 'nonexistent-model', snapshot: snap,
                               settings_snapshot: settings_snapshot, dialect: :openai)
        expect(result).to be_nil
      end

      it 'returns a frozen Hash' do
        result = catalog.fetch(id: 'gemma4', snapshot: snap,
                               settings_snapshot: settings_snapshot, dialect: :openai)
        expect(result).to be_frozen
      end
    end

    context 'when the compat set is empty' do
      let(:snap) { snapshot }

      it 'returns nil for copilot-utility-small (aliases not appended to empty set)' do
        result = catalog.fetch(id: 'copilot-utility-small', snapshot: snap,
                               settings_snapshot: settings_snapshot, dialect: :openai)
        expect(result).to be_nil
      end
    end
  end

  # ------------------------------------------------------------------ #
  # anthropic dialect                                                    #
  # ------------------------------------------------------------------ #

  describe '.list (anthropic dialect)' do
    let(:snap) { activate_vllm_h200(model: 'claude-test-model') }

    it 'returns entries with Anthropic model shape (type/id/display_name/created_at)' do
      list  = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :anthropic)
      entry = list.find { |m| m[:id] == 'claude-test-model' }
      expect(entry).not_to be_nil
      expect(entry).to include(type: 'model', id: 'claude-test-model',
                               display_name: 'claude-test-model')
      expect(entry[:created_at]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it 'includes copilot-utility-small with Anthropic shape when compat set non-empty' do
      list  = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :anthropic)
      entry = list.find { |m| m[:id] == 'copilot-utility-small' }
      expect(entry).not_to be_nil
      expect(entry).to include(type: 'model', id: 'copilot-utility-small')
    end
  end

  # ------------------------------------------------------------------ #
  # native dialect — includes unavailable / diagnostic facts             #
  # ------------------------------------------------------------------ #

  describe '.list (native dialect)' do
    context 'with an unavailable instance' do
      let(:token) do
        activate(
          provider_family: 'vllm', instance_id: 'h200',
          drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])]
        )
      end
      let(:snap) do
        tok = token
        mark_unavailable(
          provider_family:    'vllm',
          instance_id:        'h200',
          publisher_token_id: tok.publisher_token_id,
          reason:             'test instance offline'
        )
        snapshot
      end

      it 'includes the offering even when the instance is unavailable' do
        list = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :native)
        expect(list.map { |m| m[:id] }).to include('gemma4')
      end

      it 'availability_state reflects the unavailable transition' do
        list  = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :native)
        entry = list.find { |m| m[:id] == 'gemma4' }
        expect(entry[:availability_state]).to eq('unavailable')
      end
    end

    context 'with a normally activated model' do
      let(:snap) { activate_vllm_h200(model: 'gemma4') }

      it 'returns a frozen Array' do
        result = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :native)
        expect(result).to be_frozen
      end

      it 'includes required diagnostic fields in each entry' do
        list  = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :native)
        entry = list.find { |m| m[:id] == 'gemma4' }
        # 0.8.0: the published lane owns exactly one operation (the
        # representative of its coarse type) — native_list projects :operation.
        expect(entry).to include(
          :offering_id, :provider_family, :instance_id,
          :tier, :operation, :publication_state
        )
      end

      it 'includes offerings regardless of policy (native is a raw diagnostic view)' do
        Legion::Settings.loader.settings[:extensions][:llm][:model_blacklist] = ['gemma']
        Legion::LLM::Routing::SettingsState.reset!
        ss   = Legion::LLM::Routing::SettingsState.current
        list = catalog.list(snapshot: snap, settings_snapshot: ss, dialect: :native)
        # native list never applies policy — all offerings appear
        expect(list.map { |m| m[:id] }).to include('gemma4')
      end
    end
  end

  # ------------------------------------------------------------------ #
  # alias limits: metadata / registered envelope, never a lane           #
  # ------------------------------------------------------------------ #

  describe 'alias limits sourced from alias metadata or registered LLM settings' do
    let(:snap) { activate_vllm_h200(model: 'some-model') }

    it 'copilot-utility-small context_window defaults to Legion::Settings[:llm][:context_window]' do
      # Default copilot-utility-small metadata has only owned_by, no context_window.
      list  = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
      entry = list.find { |m| m[:id] == 'copilot-utility-small' }
      expect(entry[:context_window]).to eq(Legion::Settings[:llm][:context_window])
    end

    it 'copilot-utility-small max_output_tokens defaults to Legion::Settings[:llm][:max_output_tokens]' do
      list  = catalog.list(snapshot: snap, settings_snapshot: settings_snapshot, dialect: :openai)
      entry = list.find { |m| m[:id] == 'copilot-utility-small' }
      expect(entry[:max_output_tokens]).to eq(Legion::Settings[:llm][:max_output_tokens])
    end

    it 'alias metadata context_window takes precedence over registered settings' do
      Legion::Settings.loader.settings[:llm][:routing][:auto_routing_model_alias_metadata] = {
        'copilot-utility-small' => { owned_by: 'legionio', context_window: 32_768 }
      }
      Legion::LLM::Routing::SettingsState.reset!
      ss    = Legion::LLM::Routing::SettingsState.current
      list  = catalog.list(snapshot: snap, settings_snapshot: ss, dialect: :openai)
      entry = list.find { |m| m[:id] == 'copilot-utility-small' }
      expect(entry[:context_window]).to eq(32_768)
    end
  end
end
