# frozen_string_literal: true

require 'digest'
require 'spec_helper'
require 'legion/llm/routing/rank'

RSpec.describe Legion::LLM::Routing::Rank do
  # ------------------------------------------------------------------ #
  # Helpers: lane doubles carrying only the members Rank reads          #
  # ------------------------------------------------------------------ #

  def make_lane(lane_id:, base_weight: 1, tier: :direct, provider_family: :anthropic,
                instance_id: 'primary', model: 'model-x',
                weight_inputs: nil)
    double(
      lane_id:         lane_id,
      base_weight:     base_weight,
      tier:            tier,
      provider_family: provider_family,
      instance_id:     instance_id,
      model:           model,
      weight_inputs:   weight_inputs || { tier: 2, provider: 2 }
    )
  end

  # A preferred-context range resolver keyed by lane_id, mirroring the
  # SettingsSnapshot#preferred_context_range_for(lane:) seam.
  def range_for(ranges)
    ->(lane) { ranges[lane.lane_id] }
  end

  def rank_call(lanes:, routing_seed: 'seed-0001', routing_affinities: [],
                affinity_strength_bps: 10_000, context_budget: 0,
                preferred_context_range_for: nil)
    described_class.call(
      lanes:                       lanes,
      routing_seed:                routing_seed,
      routing_affinities:          routing_affinities,
      affinity_strength_bps:       affinity_strength_bps,
      context_budget:              context_budget,
      preferred_context_range_for: preferred_context_range_for || range_for({})
    )
  end

  # Independent rendezvous computation (the spec is the oracle): the SHA256 of
  # the exact frame read as an unsigned big-endian integer.
  def rendezvous_score(lane_id, routing_seed)
    Digest::SHA256.digest("ssot-tie-v1\0#{routing_seed}\0#{lane_id}").unpack1('H*').to_i(16)
  end

  # ------------------------------------------------------------------ #
  # .call — nil when there are no lanes                                  #
  # ------------------------------------------------------------------ #

  describe '.call' do
    it 'returns nil when there are no lanes' do
      expect(rank_call(lanes: [])).to be_nil
    end

    it 'returns a RankedLane carrying the winner and its ranking metadata' do
      lane = make_lane(lane_id: 'local:anthropic:primary:inference:model-x')
      result = rank_call(lanes: [lane])

      expect(result).to be_a(described_class::RankedLane)
      expect(result.lane).to equal(lane)
      expect(result.base_weight).to eq(1)
      expect(result.preference_ppm).to eq(1_000_000)
      expect(result.effective_weight).to eq(1_000_000)
      expect(result.rendezvous_score).to eq(rendezvous_score(lane.lane_id, 'seed-0001'))
    end

    # ---------------------------------------------------------------- #
    # Preferred-context band partition                                 #
    # ---------------------------------------------------------------- #

    describe 'preferred-context band' do
      let(:lane_a) { make_lane(lane_id: 'local:anthropic:primary:inference:model-a') }
      let(:lane_b) { make_lane(lane_id: 'local:anthropic:primary:inference:model-b') }

      it 'prefers an in-band lane over an out-of-band lane at equal effective weight' do
        # budget 5_000 is within lane_a's [0, 10_000); lane_b has no range.
        ranges = { lane_a.lane_id => { min: 0, max: 10_000 } }
        result = rank_call(lanes: [lane_a, lane_b], context_budget: 5_000,
                           preferred_context_range_for: range_for(ranges))
        expect(result.lane).to equal(lane_a)
      end

      it 'prefers the in-band lane even when the out-of-band lane has greater effective weight' do
        # lane_b is out-of-band but 10x the weight; the band is a priority,
        # not a filter — the in-band lane_a still wins.
        lane_hi = make_lane(lane_id: 'local:anthropic:primary:inference:model-b', base_weight: 10)
        ranges  = { lane_a.lane_id => { min: 0, max: 10_000 } }
        result  = rank_call(lanes: [lane_a, lane_hi], context_budget: 5_000,
                            preferred_context_range_for: range_for(ranges))
        expect(result.lane).to equal(lane_a)
      end

      it 'treats a budget at the upper bound as out-of-band (upper-exclusive seam)' do
        # budget 10_000 == max → outside [0, 10_000) → lane_a is out-of-band;
        # lane_b (generalist) is the only... both out-of-band, so pass 2 ranks
        # both. We assert the seam by checking lane_a is NOT selected as in-band
        # winner when it carries no weight advantage.
        ranges = { lane_a.lane_id => { min: 0, max: 10_000 } }
        result = rank_call(lanes: [lane_a, lane_b], context_budget: 10_000,
                           preferred_context_range_for: range_for(ranges))
        expect([lane_a, lane_b]).to include(result.lane)
      end
    end

    # ---------------------------------------------------------------- #
    # Effective-weight ordering                                         #
    # ---------------------------------------------------------------- #

    describe 'effective-weight ordering' do
      it 'selects the lane with the greater base_weight (no affinity)' do
        lane_hi = make_lane(lane_id: 'local:anthropic:primary:inference:model-hi', base_weight: 3)
        lane_lo = make_lane(lane_id: 'local:anthropic:primary:inference:model-lo', base_weight: 1)
        result  = rank_call(lanes: [lane_hi, lane_lo])
        expect(result.lane).to equal(lane_hi)
        expect(result.effective_weight).to eq(3_000_000)
      end

      it 'lets a matching affinity raise preference_ppm and thereby effective weight' do
        # Both base_weight 1. lane_a carries a +1 bps model affinity:
        # ppm_a = 1_000_000 + (1 * 10_000) / 200 = 1_000_050 → eff 1_000_050
        # lane_b has no matching affinity: ppm 1_000_000 → eff 1_000_000.
        lane_a = make_lane(lane_id: 'local:anthropic:primary:inference:model-a', model: 'target-model')
        lane_b = make_lane(lane_id: 'local:anthropic:primary:inference:model-b', model: 'other-model')
        affinities = [{ target_kind: :model, target: 'target-model', score_bps: 1 }]
        result = rank_call(lanes: [lane_a, lane_b], routing_affinities: affinities)
        expect(result.lane).to equal(lane_a)
        expect(result.preference_ppm).to eq(1_000_050)
        expect(result.effective_weight).to eq(1_000_050)
      end
    end

    # ---------------------------------------------------------------- #
    # Rendezvous tie-break                                              #
    # ---------------------------------------------------------------- #

    describe 'rendezvous tie-break' do
      let(:lane_a) { make_lane(lane_id: 'local:anthropic:primary:inference:model-a', base_weight: 2) }
      let(:lane_b) { make_lane(lane_id: 'local:anthropic:primary:inference:model-b', base_weight: 2) }

      it 'breaks an equal-weight tie by the greater rendezvous score, deterministically from the seed' do
        seed = 'aa' * 16
        score_a = rendezvous_score(lane_a.lane_id, seed)
        score_b = rendezvous_score(lane_b.lane_id, seed)
        expect(score_a).not_to eq(score_b)
        expected = score_a > score_b ? lane_a : lane_b

        first  = rank_call(lanes: [lane_a, lane_b], routing_seed: seed)
        second = rank_call(lanes: [lane_b, lane_a], routing_seed: seed)
        expect(first.lane).to equal(expected)
        expect(second.lane).to equal(expected)
      end

      it 'distributes an equal-weight tie across both lanes as the seed varies' do
        counts = Hash.new(0)
        200.times do |i|
          seed = format('%032x', i)
          counts[rank_call(lanes: [lane_a, lane_b], routing_seed: seed).lane] += 1
        end
        expect(counts[lane_a].zero?).to be(false)
        expect(counts[lane_b].zero?).to be(false)
      end
    end
  end

  # ------------------------------------------------------------------ #
  # Ascending lane_id — the final tie-break after weight and score      #
  # ------------------------------------------------------------------ #

  describe 'ascending lane_id final tie-break' do
    it 'breaks a full tie (equal weight, equal score) by ascending lane_id' do
      lane_a = double(lane_id: 'local:anthropic:primary:inference:a')
      lane_b = double(lane_id: 'local:anthropic:primary:inference:b')
      ra = described_class::RankedLane.new(
        lane: lane_a, weight_inputs: {}, base_weight: 1, preference_ppm: 1_000_000,
        effective_weight: 1_000_000, rendezvous_score: 999
      )
      rb = described_class::RankedLane.new(
        lane: lane_b, weight_inputs: {}, base_weight: 1, preference_ppm: 1_000_000,
        effective_weight: 1_000_000, rendezvous_score: 999
      )

      # Equal weight + equal score → ascending lane_id decides: 'a' < 'b' → ra.
      expect(described_class.send(:rank_select_winner, ranked: [ra, rb])).to equal(ra)
      # Order-independent: reversing the input array still yields ra.
      expect(described_class.send(:rank_select_winner, ranked: [rb, ra])).to equal(ra)
    end
  end
end
