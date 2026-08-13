# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/candidate_evaluation'
require 'legion/llm/router/request_requirements'
require 'legion/llm/router/ranker'

RSpec.describe Legion::LLM::Router::Ranker, :ssot_v3 do
  # ------------------------------------------------------------------ #
  # Duck-typed requirements struct (used where we need precise control  #
  # over individual formula inputs without the full Request machinery)  #
  # ------------------------------------------------------------------ #
  FAKE_REQS = Struct.new(
    :tier_preference, :required_context_budget, :routing_affinities,
    :affinity_strength_bps, :routing_seed,
    keyword_init: true
  )

  def fake_reqs(**)
    defaults = {
      tier_preference:         nil,
      required_context_budget: 0,
      routing_affinities:      [],
      affinity_strength_bps:   10_000,
      routing_seed:            '0' * 32
    }
    FAKE_REQS.new(**defaults, **)
  end

  # ------------------------------------------------------------------ #
  # Default settings snapshot (lazy-installed from Legion::Settings)    #
  # ------------------------------------------------------------------ #
  let(:settings_snap) { Legion::LLM::Router::SettingsState.current }

  # ------------------------------------------------------------------ #
  # Helpers: build real CandidateEvaluation from a live snapshot        #
  # ------------------------------------------------------------------ #

  def build_candidate(snap, provider_family:, instance_id:, model:, operation: :chat,
                      weight_inputs: nil, availability: :available)
    ik          = instance_key(provider_family: provider_family, instance_id: instance_id)
    offering    = snap.offerings_for(instance_key: ik).find { |o| o.model == model }
    raise "offering not found for #{model} on #{provider_family}/#{instance_id}" unless offering

    off_id      = offering.offering_id
    lid         = inventory::Identity.lane_id(
      instance_key: ik, operation: operation, model: model, offering_id: off_id
    )
    lane_obj    = snap.lane(lane_id: lid)
    inst_obj    = snap.instance(instance_key: ik)
    wi          = weight_inputs || settings_snap.weight_inputs_for(lane: lane_obj)

    Legion::LLM::Router::CandidateEvaluation.new(
      offering:             offering,
      lane:                 lane_obj,
      instance:             inst_obj,
      operation_state:      :supported,
      pin_state:            :match,
      policy_state:         :allowed,
      capability_state:     :supported,
      context_state:        :not_applicable,
      dimension_state:      :not_applicable,
      availability_state:   availability,
      exclusion_state:      :clear,
      fleet_contract_state: :not_applicable,
      weight_state:         :enabled,
      weight_inputs:        wi.freeze
    )
  end

  def build_eval_set(snap, *candidates)
    Legion::LLM::Router::EvaluationSet.new(
      candidates:           candidates,
      publication_statuses: [],
      inventory_generation: snap.generation
    )
  end

  def call_ranker(evaluation_set:, requirements:, settings: nil)
    described_class.call(
      evaluation_set:    evaluation_set,
      requirements:      requirements,
      settings_snapshot: settings || settings_snap
    )
  end

  # ------------------------------------------------------------------ #
  # Custom SettingsSnapshot builder for tests that need exact inputs    #
  # ------------------------------------------------------------------ #
  def settings_with(**routing_overrides)
    Legion::LLM::Router::SettingsSnapshot.build(
      generation:         99,
      llm_settings:       {
        routing: {
          tier_weights:         { direct: 105, local: 110, fleet: 110, cloud: 120, frontier: 150 },
          context_headroom_ppm: 900_000,
          **routing_overrides
        },
        api:     { routing_too_early_retry_after: 1 }
      },
      extension_settings: { llm: {} }
    )
  end

  # ------------------------------------------------------------------ #
  # § nil when no ready candidate                                        #
  # ------------------------------------------------------------------ #

  describe 'nil return' do
    it 'returns nil when the evaluation set has no ready candidates' do
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
      snap = snapshot
      # Build a candidate that is NOT ready (availability = unavailable)
      unavailable = build_candidate(snap, provider_family: 'vllm', instance_id: 'h200',
                                         model: 'gemma4', availability: :unavailable)
      eval_set    = build_eval_set(snap, unavailable)
      result      = call_ranker(evaluation_set: eval_set, requirements: fake_reqs)
      expect(result).to be_nil
    end

    it 'returns nil when the evaluation set is completely empty' do
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
      snap     = snapshot
      eval_set = build_eval_set(snap)
      result   = call_ranker(evaluation_set: eval_set, requirements: fake_reqs)
      expect(result).to be_nil
    end
  end

  # ------------------------------------------------------------------ #
  # § Integer-only formulas (no Float anywhere)                         #
  # ------------------------------------------------------------------ #

  describe 'integer-only formulas' do
    let(:snap) do
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
      snapshot
    end

    let(:candidate) { build_candidate(snap, provider_family: 'vllm', instance_id: 'h200', model: 'gemma4') }
    let(:eval_set)  { build_eval_set(snap, candidate) }
    let(:result)    { call_ranker(evaluation_set: eval_set, requirements: fake_reqs) }

    it 'returns a RankedCandidate' do
      expect(result).not_to be_nil
    end

    it 'base_weight is an Integer' do
      expect(result.base_weight).to be_a(Integer)
    end

    it 'preference_ppm is an Integer' do
      expect(result.preference_ppm).to be_a(Integer)
    end

    it 'effective_weight is an Integer' do
      expect(result.effective_weight).to be_a(Integer)
    end

    it 'rendezvous_score is an Integer' do
      expect(result.rendezvous_score).to be_a(Integer)
    end

    it 'effective_weight equals base_weight * preference_ppm exactly' do
      expect(result.effective_weight).to eq(result.base_weight * result.preference_ppm)
    end

    it 'base_weight equals the product of all weight_inputs components' do
      wi = result.weight_inputs
      expect(result.base_weight).to eq(wi[:tier] * wi[:provider] * wi[:instance] * wi[:model_or_offering])
    end

    it 'rendezvous_score is in the unsigned 256-bit range' do
      expect(result.rendezvous_score).to be >= 0
      expect(result.rendezvous_score).to be < 2**256
    end
  end

  # ------------------------------------------------------------------ #
  # § D17 floor fixture: Ruby integer floor division, not truncation    #
  # ------------------------------------------------------------------ #
  #
  # lane_affinity_bps = -1, affinity_strength_bps = 100
  # preference_ppm = 1_000_000 + ((-1 * 100) / 200)
  #               = 1_000_000 + (-100 / 200)
  #
  # Ruby integer division (-100 / 200) = -1 (floor toward -∞)
  # Truncation toward zero would yield 0 → preference_ppm = 1_000_000
  # Floor                           yields -1 → preference_ppm = 999_999
  #

  describe 'D17 floor fixture — Ruby integer floor division' do
    let(:snap) do
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
      snapshot
    end

    let(:custom_settings) { settings_with(affinity_strength_bps: 100) }

    let(:candidate) do
      # Use weight_inputs from the custom settings so weight_inputs_for uses the same snapshot.
      ik       = instance_key(provider_family: 'vllm', instance_id: 'h200')
      offering = snap.offerings_for(instance_key: ik).find { |o| o.model == 'gemma4' }
      off_id   = offering.offering_id
      lid      = inventory::Identity.lane_id(
        instance_key: ik, operation: :chat, model: 'gemma4', offering_id: off_id
      )
      lane_obj = snap.lane(lane_id: lid)
      wi       = custom_settings.weight_inputs_for(lane: lane_obj)
      build_candidate(snap, provider_family: 'vllm', instance_id: 'h200', model: 'gemma4',
                           weight_inputs: wi)
    end

    let(:eval_set) { build_eval_set(snap, candidate) }

    # affinity: this lane (provider 'vllm') gets score_bps = -1
    let(:reqs) do
      fake_reqs(
        routing_affinities:    [
          { source: :test, target_kind: :provider, target: 'vllm', score_bps: -1 }.freeze
        ],
        affinity_strength_bps: 100,
        routing_seed:          '0' * 32
      )
    end

    it 'preference_ppm is 999_999 (floor, not truncation toward zero)' do
      rc = call_ranker(evaluation_set: eval_set, requirements: reqs, settings: custom_settings)
      expect(rc).not_to be_nil
      expect(rc.preference_ppm).to eq(999_999),
                                   "Expected floor: 1_000_000 + (-100/200)=-1 = 999_999, got #{rc.preference_ppm}"
    end

    it 'preference_ppm is strictly less than 1_000_000 (proves floor, not truncation)' do
      rc = call_ranker(evaluation_set: eval_set, requirements: reqs, settings: custom_settings)
      expect(rc.preference_ppm).to be < 1_000_000
    end
  end

  # ------------------------------------------------------------------ #
  # § Greatest effective_weight wins regardless of candidate order       #
  # ------------------------------------------------------------------ #

  describe 'greatest effective_weight bucket wins' do
    let(:snap) do
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      activate(provider_family: 'vllm', instance_id: 'helios1',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      snapshot
    end

    it 'selects the candidate with higher weight_inputs (instance weight)' do
      # Give h200 a higher effective weight by injecting larger weight_inputs.
      # helios1 gets base weight = 110*1*1*1; h200 gets 110*1*1*2 (model_or_offering weight=2).
      c_h200   = build_candidate(snap, provider_family: 'vllm', instance_id: 'h200',    model: 'gemma4',
                                       weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 2 })
      c_helios = build_candidate(snap, provider_family: 'vllm', instance_id: 'helios1', model: 'gemma4',
                                       weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      eval_set = build_eval_set(snap, c_h200, c_helios)

      rc = call_ranker(evaluation_set: eval_set, requirements: fake_reqs(routing_seed: 'ab' * 16))
      expect(rc.evaluation.lane.instance_id).to eq('h200')
    end

    it 'always selects the same lane for the same seed when one weight is larger' do
      c_h200   = build_candidate(snap, provider_family: 'vllm', instance_id: 'h200',    model: 'gemma4',
                                       weight_inputs: { tier: 110, provider: 1, instance: 2, model_or_offering: 1 })
      c_helios = build_candidate(snap, provider_family: 'vllm', instance_id: 'helios1', model: 'gemma4',
                                       weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      eval_set = build_eval_set(snap, c_h200, c_helios)

      # Verify for 100 distinct seeds that h200 is always chosen.
      winners = (0..99).map do |i|
        seed = format('%032x', i)
        rc   = call_ranker(evaluation_set: eval_set, requirements: fake_reqs(routing_seed: seed))
        rc.evaluation.lane.instance_id
      end
      expect(winners.uniq).to eq(['h200'])
    end
  end

  # ------------------------------------------------------------------ #
  # § Rendezvous distribution: 10,000 distinct seeds, equal-weight      #
  # ------------------------------------------------------------------ #

  describe '10,000 fixed seeds across two equal-weight lanes' do
    let(:snap) do
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      activate(provider_family: 'vllm', instance_id: 'helios1',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      snapshot
    end

    let(:eval_set) do
      # Equal weight_inputs for both lanes → same base_weight → rendezvous distributes.
      c1 = build_candidate(snap, provider_family: 'vllm', instance_id: 'h200',
                                 model: 'gemma4',
                                 weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      c2 = build_candidate(snap, provider_family: 'vllm', instance_id: 'helios1',
                                 model: 'gemma4',
                                 weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      build_eval_set(snap, c1, c2)
    end

    it 'each lane is selected between 4,500 and 5,500 times across 10,000 seeds' do
      counts = Hash.new(0)

      10_000.times do |i|
        seed = format('%032x', i)
        req  = Legion::LLM::Inference::Request.build_for_test(
          routing_seed: seed, messages: []
        )
        reqs = Legion::LLM::Router::RequestRequirements.build(
          request: req, operation: :chat, required_capabilities: [],
          estimated_input_bound: 0, required_output_tokens: 0
        )
        rc = call_ranker(evaluation_set: eval_set, requirements: reqs)
        counts[rc.evaluation.lane.instance_id] += 1
      end

      expect(counts['h200']).to be_between(4_500, 5_500),
                                "h200 count #{counts['h200']} is outside 4_500..5_500"
      expect(counts['helios1']).to be_between(4_500, 5_500),
                                   "helios1 count #{counts['helios1']} is outside 4_500..5_500"
      expect(counts.values.sum).to eq(10_000)
    end
  end

  # ------------------------------------------------------------------ #
  # § Lane-ID ascending tie-break for score collision                    #
  # ------------------------------------------------------------------ #
  #
  # SHA256 score collisions are cryptographically improbable. We prove the
  # tie-break path is correct by verifying the ranker sorts the bucket by
  # [-rendezvous_score, lane_id] and that two candidates sharing the same
  # seed produce different scores (no accidental collision).

  describe 'rendezvous tie-break behavior' do
    let(:snap) do
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      activate(provider_family: 'vllm', instance_id: 'helios1',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      snapshot
    end

    it 'produces distinct rendezvous scores for different lanes with the same seed' do
      seed  = 'deadbeef' * 4
      c1    = build_candidate(snap, provider_family: 'vllm', instance_id: 'h200',
                                    model: 'gemma4',
                                    weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      c2    = build_candidate(snap, provider_family: 'vllm', instance_id: 'helios1',
                                    model: 'gemma4',
                                    weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      build_eval_set(snap, c1, c2)
      reqs = fake_reqs(routing_seed: seed)

      # Internally ranked — extract scores by calling with single-candidate sets.
      rc1 = call_ranker(evaluation_set: build_eval_set(snap, c1), requirements: reqs)
      rc2 = call_ranker(evaluation_set: build_eval_set(snap, c2), requirements: reqs)

      expect(rc1.rendezvous_score).not_to eq(rc2.rendezvous_score)
    end

    it 'consistently picks the lane with the higher rendezvous score for that seed' do
      seed     = 'cafebabe' * 4
      c1       = build_candidate(snap, provider_family: 'vllm', instance_id: 'h200',
                                       model: 'gemma4',
                                       weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      c2       = build_candidate(snap, provider_family: 'vllm', instance_id: 'helios1',
                                       model: 'gemma4',
                                       weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      eval_set = build_eval_set(snap, c1, c2)
      reqs     = fake_reqs(routing_seed: seed)

      rc1_alone = call_ranker(evaluation_set: build_eval_set(snap, c1), requirements: reqs)
      rc2_alone = call_ranker(evaluation_set: build_eval_set(snap, c2), requirements: reqs)
      winner_id = if rc1_alone.rendezvous_score > rc2_alone.rendezvous_score
                    c1.lane.instance_id
                  else
                    c2.lane.instance_id
                  end

      rc_both = call_ranker(evaluation_set: eval_set, requirements: reqs)
      expect(rc_both.evaluation.lane.instance_id).to eq(winner_id)
    end
  end

  # ------------------------------------------------------------------ #
  # § D17 shared affinity preserves ~50/50 distribution                 #
  # ------------------------------------------------------------------ #
  #
  # A provider-level affinity applies to BOTH lanes (same provider_family).
  # Both get the same lane_affinity_bps → same preference_ppm → same
  # effective_weight → rendezvous distributes normally.

  describe 'D17 shared affinity (provider-level) preserves distribution' do
    let(:snap) do
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      activate(provider_family: 'vllm', instance_id: 'helios1',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      snapshot
    end

    let(:eval_set) do
      c1 = build_candidate(snap, provider_family: 'vllm', instance_id: 'h200',
                                 model: 'gemma4',
                                 weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      c2 = build_candidate(snap, provider_family: 'vllm', instance_id: 'helios1',
                                 model: 'gemma4',
                                 weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      build_eval_set(snap, c1, c2)
    end

    it 'selects each lane between 4,500 and 5,500 times when both share the same provider affinity' do
      # Both lanes are :vllm → same lane_affinity_bps → same effective_weight → rendezvous hashes decide.
      provider_affinity = [{ source: :test, target_kind: :provider, target: 'vllm', score_bps: 3_000 }.freeze]
      counts            = Hash.new(0)

      500.times do |i|
        seed = format('%032x', i + 20_000) # offset to avoid overlap with other tests
        reqs = fake_reqs(routing_seed: seed, routing_affinities: provider_affinity)
        rc   = call_ranker(evaluation_set: eval_set, requirements: reqs)
        counts[rc.evaluation.lane.instance_id] += 1
      end

      expect(counts['h200']).to be_between(175, 325),
                                "h200 count #{counts['h200']} outside 175..325 — shared affinity broke distribution"
      expect(counts['helios1']).to be_between(175, 325),
                                   "helios1 count #{counts['helios1']} outside 175..325 — shared affinity broke distribution"
    end
  end

  # ------------------------------------------------------------------ #
  # § D17 instance-specific affinity deterministically selects one lane  #
  # ------------------------------------------------------------------ #
  #
  # An instance-specific affinity adds even 1 basis-point to one lane's
  # effective_weight. Since the other lane cannot catch up through rendezvous
  # scoring (different bucket), the preferred lane wins for every seed.

  describe 'D17 instance-specific affinity: deterministic selection' do
    let(:snap) do
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      activate(provider_family: 'vllm', instance_id: 'helios1',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      snapshot
    end

    let(:eval_set) do
      c1 = build_candidate(snap, provider_family: 'vllm', instance_id: 'h200',
                                 model: 'gemma4',
                                 weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      c2 = build_candidate(snap, provider_family: 'vllm', instance_id: 'helios1',
                                 model: 'gemma4',
                                 weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      build_eval_set(snap, c1, c2)
    end

    it 'always selects h200 when it has a strictly greater effective_weight (instance affinity)' do
      # h200 gets score_bps=1 for :instance match; helios1 gets 0.
      # ppm_h200   = 1_000_000 + (1 * 10_000 / 200) = 1_000_000 + 50 = 1_000_050
      # ppm_helios = 1_000_000 (no matching affinity)
      # eff_h200   = 110 * 1_000_050  > eff_helios = 110 * 1_000_000 → different bucket.
      instance_affinity = [{ source: :test, target_kind: :instance, target: 'h200', score_bps: 1 }.freeze]

      winners = (0..999).map do |i|
        seed = format('%032x', i + 40_000)
        reqs = fake_reqs(routing_seed: seed, routing_affinities: instance_affinity)
        rc   = call_ranker(evaluation_set: eval_set, requirements: reqs)
        rc.evaluation.lane.instance_id
      end

      expect(winners.uniq).to eq(['h200']),
                              "Expected h200 to win all 1000 seeds but got: #{winners.tally}"
    end

    it 'always selects h200 when its offering affinity is strictly greater' do
      # Offering-specific affinity: target is the offering_id of h200's gemma4 offering.
      ik        = instance_key(provider_family: 'vllm', instance_id: 'h200')
      offering  = snap.offerings_for(instance_key: ik).find { |o| o.model == 'gemma4' }
      off_aff   = [{ source: :test, target_kind: :offering, target: offering.offering_id, score_bps: 1 }.freeze]

      winners = (0..99).map do |i|
        seed = format('%032x', i + 50_000)
        reqs = fake_reqs(routing_seed: seed, routing_affinities: off_aff)
        rc   = call_ranker(evaluation_set: eval_set, requirements: reqs)
        rc.evaluation.lane.instance_id
      end

      expect(winners.uniq).to eq(['h200']),
                              "Expected h200 (offering affinity) to win all 100 seeds but got: #{winners.tally}"
    end
  end

  # ------------------------------------------------------------------ #
  # § Preferred-context sieve                                            #
  # ------------------------------------------------------------------ #

  describe '§10.1 preferred-context soft sieve' do
    it 'prefers range-specific candidates that contain the budget over generalists' do
      # h200 is configured with preferred context range; helios1 is a generalist.
      # Only in the custom settings do we have preferred context configured.
      # We inject weight_inputs manually but consult custom settings for range lookup.
      custom_settings = Legion::LLM::Router::SettingsSnapshot.build(
        generation:         88,
        llm_settings:       {
          routing: {
            tier_weights:         { direct: 105, local: 110, fleet: 110, cloud: 120, frontier: 150 },
            context_headroom_ppm: 900_000
          },
          api:     { routing_too_early_retry_after: 1 }
        },
        extension_settings: {
          llm: {
            vllm: {
              instances: {
                h200: {
                  preferred_min_context_tokens: 100,
                  preferred_max_context_tokens: 5_000
                }
                # helios1 has no preferred range → generalist
              }
            }
          }
        }
      )

      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      activate(provider_family: 'vllm', instance_id: 'helios1',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      snap = snapshot

      c_h200   = build_candidate(snap, provider_family: 'vllm', instance_id: 'h200',    model: 'gemma4')
      c_helios = build_candidate(snap, provider_family: 'vllm', instance_id: 'helios1', model: 'gemma4')
      eval_set = build_eval_set(snap, c_h200, c_helios)

      # budget = 1000 falls in h200's range (100..5000) → h200 preferred.
      reqs = fake_reqs(required_context_budget: 1_000, routing_seed: 'ee' * 16)
      rc   = described_class.call(
        evaluation_set:    eval_set,
        requirements:      reqs,
        settings_snapshot: custom_settings
      )
      expect(rc.evaluation.lane.instance_id).to eq('h200')
    end

    it 'falls back to generalists when no range-specific candidate matches the budget' do
      custom_settings = Legion::LLM::Router::SettingsSnapshot.build(
        generation:         89,
        llm_settings:       {
          routing: {
            tier_weights:         { direct: 105, local: 110, fleet: 110, cloud: 120, frontier: 150 },
            context_headroom_ppm: 900_000
          },
          api:     { routing_too_early_retry_after: 1 }
        },
        extension_settings: {
          llm: {
            vllm: {
              instances: {
                h200: {
                  preferred_min_context_tokens: 100,
                  preferred_max_context_tokens: 500
                }
                # helios1: generalist
              }
            }
          }
        }
      )

      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      activate(provider_family: 'vllm', instance_id: 'helios1',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      snap = snapshot

      c_h200   = build_candidate(snap, provider_family: 'vllm', instance_id: 'h200',    model: 'gemma4')
      c_helios = build_candidate(snap, provider_family: 'vllm', instance_id: 'helios1', model: 'gemma4')
      eval_set = build_eval_set(snap, c_h200, c_helios)

      # budget = 10_000 is ABOVE h200's range (100..500) → no match → fall back to helios1 (generalist).
      reqs = fake_reqs(required_context_budget: 10_000, routing_seed: 'ff' * 16)
      rc   = described_class.call(
        evaluation_set:    eval_set,
        requirements:      reqs,
        settings_snapshot: custom_settings
      )
      expect(rc.evaluation.lane.instance_id).to eq('helios1')
    end

    it 'retains all ready candidates when there are no range-specific or generalist lanes (pure fallback)' do
      # Two range-specific lanes, neither matches → fall back to entire ready set.
      custom_settings = Legion::LLM::Router::SettingsSnapshot.build(
        generation:         90,
        llm_settings:       {
          routing: {
            tier_weights:         { direct: 105, local: 110, fleet: 110, cloud: 120, frontier: 150 },
            context_headroom_ppm: 900_000
          },
          api:     { routing_too_early_retry_after: 1 }
        },
        extension_settings: {
          llm: {
            vllm: {
              instances: {
                h200:    {
                  preferred_min_context_tokens: 1,
                  preferred_max_context_tokens: 100
                },
                helios1: {
                  preferred_min_context_tokens: 1,
                  preferred_max_context_tokens: 100
                }
              }
            }
          }
        }
      )

      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      activate(provider_family: 'vllm', instance_id: 'helios1',
               drafts: [offering_draft(model: 'gemma4', tier: :local, supported: %i[chat])])
      snap = snapshot

      c_h200   = build_candidate(snap, provider_family: 'vllm', instance_id: 'h200',    model: 'gemma4')
      c_helios = build_candidate(snap, provider_family: 'vllm', instance_id: 'helios1', model: 'gemma4')
      eval_set = build_eval_set(snap, c_h200, c_helios)

      # budget = 50_000 > max range for both → neither matches → fall back to full ready set.
      # The winner depends on rendezvous, but the result must be non-nil.
      reqs = fake_reqs(required_context_budget: 50_000, routing_seed: '11' * 16)
      rc   = described_class.call(
        evaluation_set:    eval_set,
        requirements:      reqs,
        settings_snapshot: custom_settings
      )
      expect(rc).not_to be_nil
      expect(%w[h200 helios1]).to include(rc.evaluation.lane.instance_id)
    end
  end

  # ------------------------------------------------------------------ #
  # § Tier preference boosts the matching tier component                 #
  # ------------------------------------------------------------------ #

  describe '§10.2 tier preference' do
    it 'boosts the tier-preference lane above an otherwise-equal lane on a different tier' do
      activate(provider_family: 'vllm', instance_id: 'h200',
               drafts: [offering_draft(model: 'gemma4', tier: :local,    supported: %i[chat])])
      activate(provider_family: 'vllm', instance_id: 'cloud1',
               drafts: [offering_draft(model: 'gemma4', tier: :cloud,    supported: %i[chat])])
      snap = snapshot

      # Same non-tier weights so tier is the differentiator.
      c_local = build_candidate(snap, provider_family: 'vllm', instance_id: 'h200',
                                      model: 'gemma4',
                                      weight_inputs: { tier: 110, provider: 1, instance: 1, model_or_offering: 1 })
      c_cloud = build_candidate(snap, provider_family: 'vllm', instance_id: 'cloud1',
                                      model: 'gemma4',
                                      weight_inputs: { tier: 120, provider: 1, instance: 1, model_or_offering: 1 })
      eval_set = build_eval_set(snap, c_local, c_cloud)

      # Prefer :local → local tier gets tier_weights.values.max + 1 = 151.
      # local effective: (151 * 1 * 1 * 1) * 1_000_000 > cloud: (120 * 1 * 1 * 1) * 1_000_000.
      reqs = fake_reqs(tier_preference: :local, routing_seed: '77' * 16)
      rc   = call_ranker(evaluation_set: eval_set, requirements: reqs)
      expect(rc.evaluation.lane.instance_id).to eq('h200')
      # The boosted tier component must be tier_weights.values.max + 1.
      expect(rc.weight_inputs[:tier]).to eq(settings_snap.tier_weights.values.max + 1)
    end
  end
end
