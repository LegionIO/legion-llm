# frozen_string_literal: true

require 'digest'
require 'legion/logging/helper'

module Legion
  module LLM
    module Routing
      # Soft ordering of eligible lanes: preferred-context band, weight x
      # affinity, rendezvous tie-break, winner selection.
      #
      # A stateless ranking engine. Pure function of its inputs — it reads no
      # inventory and reaches no Settings at call time; the caller resolves the
      # per-lane preferred-context range and the affinity strength beforehand
      # and hands them in. Reproduces the baseline Ranker's ranking math exactly.
      module Rank
        include Legion::Logging::Helper

        MAX_AFFINITY_BPS     = 10_000
        MIN_PREFERENCE_PPM   = 500_000
        MAX_PREFERENCE_PPM   = 1_500_000
        AFFINITY_PPM_DIVISOR = 200
        # Exact byte prefix for the rendezvous frame.
        RENDEZVOUS_PREFIX    = "ssot-tie-v1\0"
        private_constant :MAX_AFFINITY_BPS, :MIN_PREFERENCE_PPM, :MAX_PREFERENCE_PPM,
                         :AFFINITY_PPM_DIVISOR, :RENDEZVOUS_PREFIX

        # Immutable result of ranking one eligible lane: the lane plus the
        # scalar ranking inputs that produced its effective weight and its
        # rendezvous score.
        class RankedLane
          attr_reader :lane, :weight_inputs, :base_weight, :preference_ppm,
                      :effective_weight, :rendezvous_score

          def initialize(lane:, weight_inputs:, base_weight:, preference_ppm:,
                         effective_weight:, rendezvous_score:)
            @lane             = lane
            @weight_inputs    = weight_inputs&.freeze
            @base_weight      = base_weight
            @preference_ppm   = preference_ppm
            @effective_weight = effective_weight
            @rendezvous_score = rendezvous_score
            freeze
          end
        end

        # Rank the eligible lanes and return the winner as a +RankedLane+, or
        # +nil+ when there are no lanes.
        #
        # Winner selection is: greatest effective_weight bucket, then greatest
        # rendezvous score, then ascending lane_id (cryptographically
        # improbable SHA256 collision). The preferred-context band is a
        # priority, not a filter: pass 1 ranks the in-band lanes; pass 2 (only
        # when pass 1 is empty) ranks everything else, band-ignoring.
        #
        # @param lanes [Array] eligible inventory lanes (LaneRecord shape).
        # @param routing_seed [String] per-attempt seed for the rendezvous frame.
        # @param routing_affinities [Array<Hash>] request affinities, each
        #   { target_kind:, target:, score_bps: }.
        # @param affinity_strength_bps [Integer] 0..10_000 affinity strength.
        # @param context_budget [Integer] the request's required context budget.
        # @param preferred_context_range_for [#call] resolves a lane's preferred
        #   { min:, max: } range (nil-open bounds) or nil when unconfigured.
        # @return [RankedLane, nil]
        def rank(lanes:, routing_seed:, routing_affinities:, affinity_strength_bps:,
                 context_budget:, preferred_context_range_for:)
          lanes = Array(lanes)
          return nil if lanes.empty?

          log.debug("[llm][rank] action=rank eligible_count=#{lanes.size} " \
                    "seed=#{routing_seed[0, 8]}...")

          in_band, out_of_band = rank_band_partition(
            lanes:                       lanes,
            context_budget:              context_budget,
            preferred_context_range_for: preferred_context_range_for
          )

          log.debug("[llm][rank] action=preferred_band_partition eligible=#{lanes.size} " \
                    "in_band=#{in_band.size} out_of_band=#{out_of_band.size}")

          # Only the selected pass is ranked, so the ranked set is exactly the
          # lanes eligible for this attempt.
          ranked = if in_band.any?
                     rank_compute_ranked(
                       lanes:                 in_band,
                       routing_seed:          routing_seed,
                       routing_affinities:    routing_affinities,
                       affinity_strength_bps: affinity_strength_bps
                     )
                   else
                     rank_compute_ranked(
                       lanes:                 out_of_band,
                       routing_seed:          routing_seed,
                       routing_affinities:    routing_affinities,
                       affinity_strength_bps: affinity_strength_bps
                     )
                   end

          rank_select_winner(ranked:)
        end

        private

        # Partition lanes by preferred-band containment. A lane with no
        # configured range is out_of_band (generalist). A lane whose range does
        # not contain the budget is also out_of_band — never excluded.
        def rank_band_partition(lanes:, context_budget:, preferred_context_range_for:)
          in_band     = []
          out_of_band = []
          lanes.each do |lane|
            range = preferred_context_range_for.call(lane)
            if range && rank_range_contains?(range:, budget: context_budget)
              in_band << lane
            else
              out_of_band << lane
            end
          end
          [in_band, out_of_band]
        end

        # True when +budget+ falls within the (nil-open) range [min, max) —
        # the range seam is upper-exclusive (budget < max).
        def rank_range_contains?(range:, budget:)
          (range[:min].nil? || budget >= range[:min]) &&
            (range[:max].nil? || budget < range[:max])
        end

        # Compute the base weight, preference ppm, effective weight, and
        # rendezvous score for each lane, returning a frozen RankedLane each.
        def rank_compute_ranked(lanes:, routing_seed:, routing_affinities:, affinity_strength_bps:)
          lanes.map do |lane|
            base  = lane.base_weight
            ppm   = rank_preference_ppm(
              lane:                  lane,
              routing_affinities:    routing_affinities,
              affinity_strength_bps: affinity_strength_bps
            )
            eff   = base * ppm
            score = rank_rendezvous_score(lane:, routing_seed:)

            log.debug("[llm][rank] action=ranked lane=#{lane.lane_id} " \
                      "base=#{base} ppm=#{ppm} eff=#{eff}")

            RankedLane.new(
              lane:             lane,
              weight_inputs:    lane.weight_inputs,
              base_weight:      base,
              preference_ppm:   ppm,
              effective_weight: eff,
              rendezvous_score: score
            )
          end
        end

        # preference_ppm = 1_000_000 + (lane_affinity * strength) / 200, with
        # Ruby integer floor division, clamped to 500_000..1_500_000.
        def rank_preference_ppm(lane:, routing_affinities:, affinity_strength_bps:)
          lane_aff = rank_lane_affinity(lane:, routing_affinities:)
          raw      = 1_000_000 + ((lane_aff * affinity_strength_bps) / AFFINITY_PPM_DIVISOR)
          raw.clamp(MIN_PREFERENCE_PPM, MAX_PREFERENCE_PPM)
        end

        # Sum every matching affinity score_bps for this lane, then clamp to
        # [-10_000, 10_000] (one clamp, after summation).
        def rank_lane_affinity(lane:, routing_affinities:)
          return 0 if routing_affinities.empty?

          raw_sum = routing_affinities.sum { |entry| rank_affinity_score(entry:, lane:) }
          raw_sum.clamp(-MAX_AFFINITY_BPS, MAX_AFFINITY_BPS)
        end

        # Returns +entry[:score_bps]+ when the entry matches this lane, else 0.
        # Matching target kinds: tier, provider, instance, model, offering.
        def rank_affinity_score(entry:, lane:)
          target = entry[:target].to_s
          score  = entry[:score_bps]
          case entry[:target_kind]
          when :tier     then lane.tier.to_s            == target ? score : 0
          when :provider then lane.provider_family.to_s == target ? score : 0
          when :instance then lane.instance_id.to_s     == target ? score : 0
          when :model    then lane.model.to_s == target ? score : 0
          when :offering then lane.lane_id.to_s == target ? score : 0
          else 0
          end
        end

        # SHA256("ssot-tie-v1\0" + routing_seed + "\0" + lane_id) read as an
        # unsigned 256-bit big-endian Integer.
        def rank_rendezvous_score(lane:, routing_seed:)
          frame = "#{RENDEZVOUS_PREFIX}#{routing_seed}\0#{lane.lane_id}"
          Digest::SHA256.digest(frame).unpack1('H*').to_i(16)
        end

        # 1. Greatest effective_weight bucket.
        # 2. Within the bucket: greatest rendezvous_score.
        # 3. Tie-break (cryptographically improbable SHA256 collision):
        #    ascending lane_id.
        def rank_select_winner(ranked:)
          max_ew = ranked.map(&:effective_weight).max
          bucket = ranked.select { |rc| rc.effective_weight == max_ew }
          winner = bucket.min_by { |rc| [-rc.rendezvous_score, rc.lane.lane_id] }
          log.debug("[llm][rank] action=selected lane=#{winner.lane.lane_id} " \
                    "eff=#{winner.effective_weight}")
          winner
        end
      end
    end
  end
end
