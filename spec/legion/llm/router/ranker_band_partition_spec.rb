# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/candidate_evaluation'
require 'legion/llm/router/ranker'

BandRequirements = Struct.new(
  :tier_preference, :required_context_budget, :routing_affinities,
  :affinity_strength_bps, :routing_seed,
  keyword_init: true
)

RSpec.describe Legion::LLM::Router::Ranker, 'preferred-context band partition', :ssot_v3 do
  def band_settings(cloud_weight: 100)
    Legion::LLM::Router::SettingsSnapshot.build(
      generation:         101,
      llm_settings:       {
        routing: {
          tier_weights:         { direct: 150, local: 140, fleet: 130, cloud: 110, frontier: 100 },
          context_headroom_ppm: 900_000
        },
        api:     { routing_too_early_retry_after: 1 }
      },
      extension_settings: {
        llm: {
          vllm:   {
            instances: {
              'helios-0001': {
                weight: 115, preferred_min_context_tokens: 48_000,
                preferred_max_context_tokens: 262_000
              },
              h200:          {
                weight: 110, preferred_min_context_tokens: 4_096,
                preferred_max_context_tokens: 48_000
              }
            }
          },
          bedrock: { instances: { uais: { weight: cloud_weight } } }
        }
      }
    )
  end

  def requirements(budget)
    BandRequirements.new(
      tier_preference:         nil,
      required_context_budget: budget,
      routing_affinities:      [],
      affinity_strength_bps:   10_000,
      routing_seed:            'ab' * 16
    )
  end

  def candidate(snap, settings, provider_family:, instance_id:, model:)
    ik       = instance_key(provider_family: provider_family, instance_id: instance_id)
    offering = snap.offerings_for(instance_key: ik).find { |entry| entry.model == model }
    lane_id  = inventory::Identity.lane_id(
      instance_key: ik, operation: :chat, model: model, offering_id: offering.offering_id
    )
    lane     = snap.lane(lane_id: lane_id)

    Legion::LLM::Router::CandidateEvaluation.new(
      offering:             offering,
      lane:                 lane,
      instance:             snap.instance(instance_key: ik),
      operation_state:      :supported,
      pin_state:            :match,
      policy_state:         :allowed,
      capability_state:     :supported,
      context_state:        :not_applicable,
      dimension_state:      :not_applicable,
      availability_state:   :available,
      exclusion_state:      :clear,
      fleet_contract_state: :not_applicable,
      weight_state:         :enabled,
      weight_inputs:        settings.weight_inputs_for(lane: lane).freeze
    )
  end

  def frozen_candidates(settings: band_settings)
    activate(provider_family: 'vllm', instance_id: 'helios-0001',
             drafts: [offering_draft(model: 'helios-model', tier: :direct, supported: %i[chat])])
    activate(provider_family: 'vllm', instance_id: 'h200',
             drafts: [offering_draft(model: 'h200-model', tier: :direct, supported: %i[chat])])
    activate(provider_family: 'bedrock', instance_id: 'uais',
             drafts: [offering_draft(model: 'cloud-model', tier: :cloud, supported: %i[chat])])
    snap     = snapshot
    candidates = [
      candidate(snap, settings, provider_family: 'vllm', instance_id: 'helios-0001', model: 'helios-model'),
      candidate(snap, settings, provider_family: 'vllm', instance_id: 'h200', model: 'h200-model'),
      candidate(snap, settings, provider_family: 'bedrock', instance_id: 'uais', model: 'cloud-model')
    ]
    [snap, settings, candidates]
  end

  def rank(settings:, candidates:, budget:)
    evaluation_set = Legion::LLM::Router::EvaluationSet.new(
      candidates: candidates, publication_statuses: [], inventory_generation: snapshot.generation
    )
    described_class.call(
      evaluation_set: evaluation_set, requirements: requirements(budget), settings_snapshot: settings
    )
  end

  it 'keeps every ready lane in pass 2 when no preferred band matches' do
    _snap, settings, candidates = frozen_candidates

    winner = rank(settings: settings, candidates: candidates, budget: 307_604)
    expect(winner.evaluation.lane.instance_id).to eq('helios-0001')

    ranker = described_class.new(
      evaluation_set: nil, requirements: requirements(307_604), settings_snapshot: settings
    )
    in_band, out_of_band = ranker.send(:band_partition, candidates)
    expect(in_band).to be_empty
    expect(in_band.size + out_of_band.size).to eq(candidates.size)
  end

  it 'keeps in-band steering ahead of a higher-weight out-of-band lane' do
    _snap, settings, candidates = frozen_candidates

    expect(rank(settings: settings, candidates: candidates, budget: 10_000)
      .evaluation.lane.instance_id).to eq('h200')
    expect(rank(settings: settings, candidates: candidates, budget: 100_000)
      .evaluation.lane.instance_id).to eq('helios-0001')
  end

  it 'does not rank pass 2 when pass 1 is non-empty' do
    settings = band_settings(cloud_weight: 10_000)
    _snap, _settings, candidates = frozen_candidates(settings: settings)

    winner = rank(settings: settings, candidates: candidates, budget: 10_000)
    expect(winner.evaluation.lane.instance_id).to eq('h200')
  end
end
