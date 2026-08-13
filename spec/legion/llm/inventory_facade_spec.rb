# frozen_string_literal: true

require 'spec_helper'

# SSOT v3 Phase 2 §13.1 read-only facade spec.
# Tests the three non-colliding facade methods on Legion::LLM::Inventory:
#   snapshot, instances, models
#
# NOTE: providers, offerings, and lanes are NOT covered here because those names
# already exist on Legion::LLM::Inventory with incompatible signatures (they read
# from the live Concurrent::Map store). The SSOT v3 equivalents are bridged as
# providers_from/instances/models; this file covers the non-colliding additions.
RSpec.describe Legion::LLM::Inventory, :ssot_v3 do
  describe '.snapshot' do
    it 'delegates to the Phase 1 Registry and returns a Snapshot' do
      snap = described_class.snapshot
      expect(snap).to respond_to(:each_instance)
      expect(snap).to respond_to(:each_offering)
      expect(snap).to respond_to(:each_lane)
      expect(snap).to respond_to(:generation)
    end

    it 'returns a fresh snapshot after an instance is activated' do
      before_gen = described_class.snapshot.generation
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
      after_gen = described_class.snapshot.generation
      expect(after_gen).to be > before_gen
    end

    it 'does not mutate the registry' do
      snap_before = described_class.snapshot
      gen_before = snap_before.generation
      # Calling snapshot again must not change generation
      described_class.snapshot
      snap_after = Legion::Extensions::Llm::Inventory::Registry.snapshot
      expect(snap_after.generation).to eq(gen_before)
    end
  end

  describe '.instances' do
    context 'with no activated instances' do
      it 'returns a frozen empty Array' do
        result = described_class.instances(snapshot: snapshot)
        expect(result).to be_frozen
        expect(result).to be_empty
      end
    end

    context 'with one activated instance' do
      before do
        activate(provider_family: 'vllm', instance_id: 'h200',
                 drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
      end

      it 'returns a frozen Array with one frozen Hash' do
        result = described_class.instances(snapshot: snapshot)
        expect(result).to be_frozen
        expect(result.size).to eq(1)
        expect(result.first).to be_frozen
      end

      it 'projects canonical fields on each instance' do
        inst = described_class.instances(snapshot: snapshot).first
        expect(inst[:provider_family]).to eq(:vllm)
        expect(inst[:instance_id]).to eq('h200')
        expect(inst[:availability]).to eq(:available)
        expect(inst).to have_key(:publisher_id)
        expect(inst).to have_key(:publisher_token_id)
        expect(inst).to have_key(:published_sequence)
        expect(inst).to have_key(:published_at)
      end

      it 'does not expose callable or callable_handle in the projection' do
        inst = described_class.instances(snapshot: snapshot).first
        expect(inst).not_to have_key(:callable)
        expect(inst).not_to have_key(:callable_handle)
      end
    end

    context 'with two providers/instances in canonical order' do
      before do
        activate(provider_family: 'vllm', instance_id: 'h200',
                 drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
        activate(provider_family: 'ollama', instance_id: 'local',
                 drafts: [offering_draft(model: 'llama3', supported: %i[chat])])
      end

      it 'returns both instances' do
        result = described_class.instances(snapshot: snapshot)
        expect(result.size).to eq(2)
      end

      it 'projects the correct provider families' do
        families = described_class.instances(snapshot: snapshot).map { |h| h[:provider_family].to_s }
        expect(families).to include('vllm', 'ollama')
      end

      it 'filters by provider_family' do
        result = described_class.instances(snapshot: snapshot, filters: { provider_family: 'vllm' })
        expect(result.size).to eq(1)
        expect(result.first[:provider_family]).to eq(:vllm)
      end

      it 'filters by instance_id' do
        result = described_class.instances(snapshot: snapshot, filters: { instance_id: 'local' })
        expect(result.size).to eq(1)
        expect(result.first[:instance_id]).to eq('local')
      end

      it 'returns empty when filter matches no instance' do
        result = described_class.instances(snapshot: snapshot, filters: { provider_family: 'anthropic' })
        expect(result).to be_empty
      end
    end

    context 'availability filter' do
      before do
        @token = activate(provider_family: 'vllm', instance_id: 'h200',
                          drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
        activate(provider_family: 'ollama', instance_id: 'local',
                 drafts: [offering_draft(model: 'llama3', supported: %i[chat])])
        mark_unavailable(provider_family: 'vllm', instance_id: 'h200',
                         publisher_token_id: @token.publisher_token_id)
      end

      it 'filters to available instances only' do
        result = described_class.instances(snapshot: snapshot, filters: { availability: :available })
        expect(result.all? { |h| h[:availability] == :available }).to be true
        expect(result.none? { |h| h[:provider_family] == :vllm }).to be true
      end

      it 'filters to unavailable instances only' do
        result = described_class.instances(snapshot: snapshot, filters: { availability: :unavailable })
        expect(result.all? { |h| h[:availability] == :unavailable }).to be true
        expect(result.none? { |h| h[:provider_family] == :ollama }).to be true
      end
    end

    it 'raises ArgumentError for an unknown filter key' do
      expect do
        described_class.instances(snapshot: snapshot, filters: { bogus_key: 'x' })
      end.to raise_error(ArgumentError, /bogus_key/)
    end

    it 'does not write to the registry' do
      gen_before = snapshot.generation
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
      snap = snapshot
      described_class.instances(snapshot: snap)
      expect(Legion::Extensions::Llm::Inventory::Registry.snapshot.generation).to eq(snap.generation)
    end
  end

  describe '.models' do
    context 'with no activated instances' do
      it 'returns a frozen empty Array' do
        result = described_class.models(snapshot: snapshot)
        expect(result).to be_frozen
        expect(result).to be_empty
      end
    end

    context 'with one instance offering two models' do
      before do
        activate(
          provider_family: 'vllm', instance_id: 'h200',
          drafts: [
            offering_draft(model: 'gemma4', supported: %i[chat]),
            offering_draft(model: 'llama3', supported: %i[chat embed], native: 'llama3')
          ]
        )
      end

      it 'returns a frozen sorted Array of distinct model Strings' do
        result = described_class.models(snapshot: snapshot)
        expect(result).to be_frozen
        expect(result).to eq(%w[gemma4 llama3])
      end
    end

    context 'with two providers sharing a model name' do
      before do
        activate(provider_family: 'vllm', instance_id: 'h200',
                 drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
        activate(provider_family: 'ollama', instance_id: 'local',
                 drafts: [offering_draft(model: 'gemma4', supported: %i[chat], native: 'gemma4-ollama')])
      end

      it 'deduplicates the same model across providers' do
        result = described_class.models(snapshot: snapshot)
        expect(result).to eq(%w[gemma4])
      end
    end

    context 'filtering by provider_family' do
      before do
        activate(provider_family: 'vllm', instance_id: 'h200',
                 drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
        activate(provider_family: 'ollama', instance_id: 'local',
                 drafts: [offering_draft(model: 'llama3', supported: %i[chat], native: 'llama3-ollama')])
      end

      it 'returns only models for the specified provider' do
        result = described_class.models(snapshot: snapshot, filters: { provider_family: 'ollama' })
        expect(result).to eq(%w[llama3])
      end
    end

    context 'filtering by tier' do
      before do
        activate(provider_family: 'vllm', instance_id: 'h200',
                 drafts: [
                   offering_draft(model: 'local-model', tier: :local, supported: %i[chat]),
                   offering_draft(model: 'direct-model', tier: :direct, supported: %i[chat],
                                  native: 'direct-model-v2')
                 ])
      end

      it 'returns only models matching the tier' do
        result = described_class.models(snapshot: snapshot, filters: { tier: :local })
        expect(result).to eq(%w[local-model])
      end
    end

    context 'filtering by operation' do
      before do
        activate(
          provider_family: 'vllm', instance_id: 'h200',
          drafts: [
            offering_draft(model: 'chat-only', supported: %i[chat], unsupported: %i[embed]),
            offering_draft(model: 'embed-capable', supported: %i[chat embed], native: 'embed-capable-v2')
          ]
        )
      end

      it 'includes only models whose offering supports the requested operation' do
        result = described_class.models(snapshot: snapshot, filters: { operation: :embed })
        expect(result).to include('embed-capable')
        expect(result).not_to include('chat-only')
      end
    end

    it 'raises ArgumentError for an unknown filter key' do
      expect do
        described_class.models(snapshot: snapshot, filters: { unknown_filter: 'x' })
      end.to raise_error(ArgumentError, /unknown_filter/)
    end

    it 'raises ArgumentError when multiple unknown filter keys are present' do
      expect do
        described_class.models(snapshot: snapshot, filters: { foo: 'a', bar: 'b' })
      end.to raise_error(ArgumentError)
    end

    it 'does not write to the registry' do
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
      snap = snapshot
      described_class.models(snapshot: snap)
      expect(Legion::Extensions::Llm::Inventory::Registry.snapshot.generation).to eq(snap.generation)
    end
  end

  describe '.providers_from (SSOT v3 bridge for `providers`)' do
    context 'with no activated instances' do
      it 'returns a frozen empty Array' do
        result = described_class.providers_from(snapshot: snapshot)
        expect(result).to be_frozen
        expect(result).to be_empty
      end
    end

    context 'with two providers' do
      before do
        activate(provider_family: 'vllm', instance_id: 'h200',
                 drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
        activate(provider_family: 'ollama', instance_id: 'local',
                 drafts: [offering_draft(model: 'llama3', supported: %i[chat], native: 'llama3-ollama')])
      end

      it 'returns a sorted frozen Array of distinct provider family Strings' do
        result = described_class.providers_from(snapshot: snapshot)
        expect(result).to be_frozen
        expect(result).to eq(%w[ollama vllm])
      end

      it 'filters by provider_family' do
        result = described_class.providers_from(snapshot: snapshot, filters: { provider_family: 'vllm' })
        expect(result).to eq(%w[vllm])
      end

      it 'returns empty when no provider matches the filter' do
        result = described_class.providers_from(snapshot: snapshot, filters: { provider_family: 'anthropic' })
        expect(result).to be_empty
      end
    end

    it 'raises ArgumentError for an unknown filter key' do
      expect do
        described_class.providers_from(snapshot: snapshot, filters: { garbage: 'y' })
      end.to raise_error(ArgumentError, /garbage/)
    end

    it 'does not mutate the registry' do
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
      snap = snapshot
      gen = snap.generation
      described_class.providers_from(snapshot: snap)
      expect(Legion::Extensions::Llm::Inventory::Registry.snapshot.generation).to eq(gen)
    end
  end

  describe 'generation isolation' do
    it 'two snapshots with different generations project independently' do
      # Capture snapshot before any instance exists
      snap1 = described_class.snapshot

      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
      snap2 = described_class.snapshot

      expect(snap1.generation).to be < snap2.generation
      expect(described_class.models(snapshot: snap1)).to be_empty
      expect(described_class.models(snapshot: snap2)).to include('gemma4')
    end
  end
end
