# frozen_string_literal: true

require 'digest'
require 'legion/extensions/llm/taxonomies'

module Legion
  module LLM
    module Router
      # Immutable result of ranking one ready candidate.
      # PRIVATE: defined in ranker.rb; no caller outside router.rb may use it directly.
      class RankedCandidate
        attr_reader :evaluation, :weight_inputs, :base_weight, :preference_ppm,
                    :effective_weight, :rendezvous_score

        def initialize(evaluation:, weight_inputs:, base_weight:, preference_ppm:,
                       effective_weight:, rendezvous_score:)
          @evaluation       = evaluation
          @weight_inputs    = weight_inputs.freeze
          @base_weight      = base_weight
          @preference_ppm   = preference_ppm
          @effective_weight = effective_weight
          @rendezvous_score = rendezvous_score
          freeze
        end
      end
      private_constant :RankedCandidate

      # Soft preference, integer weight/affinity, and rendezvous tie-breaking (§10).
      # Returns the winning +RankedCandidate+, or +nil+ when no ready candidate exists.
      #
      # PRIVATE — no call site outside router.rb may invoke Ranker directly.
      class Ranker
        include Legion::Logging::Helper

        MAX_AFFINITY_BPS     = 10_000
        MIN_PREFERENCE_PPM   = 500_000
        MAX_PREFERENCE_PPM   = 1_500_000
        AFFINITY_PPM_DIVISOR = 200
        # Exact byte prefix for the rendezvous frame (§10.3 / D15).
        RENDEZVOUS_PREFIX    = "ssot-tie-v1\0"
        private_constant :MAX_AFFINITY_BPS, :MIN_PREFERENCE_PPM, :MAX_PREFERENCE_PPM,
                         :AFFINITY_PPM_DIVISOR, :RENDEZVOUS_PREFIX

        # @param evaluation_set  [EvaluationSet]
        # @param requirements    [RequestRequirements]  (duck-typed: responds to
        #   #tier_preference, #required_context_budget, #routing_affinities,
        #   #affinity_strength_bps, #routing_seed)
        # @param settings_snapshot [SettingsSnapshot]
        # @return [RankedCandidate, nil]
        def self.call(evaluation_set:, requirements:, settings_snapshot:)
          new(evaluation_set:    evaluation_set,
              requirements:      requirements,
              settings_snapshot: settings_snapshot).call
        end

        def initialize(evaluation_set:, requirements:, settings_snapshot:)
          @evaluation_set    = evaluation_set
          @requirements      = requirements
          @settings_snapshot = settings_snapshot
        end

        def call
          # Step 1 (§10): start with ready candidates only.
          ready = @evaluation_set.ready_candidates
          return nil if ready.empty?

          log.debug("[llm][ranker] action=rank ready_count=#{ready.size} " \
                    "seed=#{@requirements.routing_seed[0, 8]}...")

          # Step 2 (§10.1): preferred-context soft sieve.
          sieved = preferred_context_sieve(ready)

          # Steps 3–4 (§10.2 + D17): base weight, affinity, effective weight.
          # Step 5 (§10.3): rendezvous score.
          ranked = compute_ranked(sieved)

          # Select the winner (greatest effective_weight bucket → greatest rendezvous
          # score → lexicographically ascending lane_id for cryptographically
          # improbable score collisions).
          select_winner(ranked)
        end

        private

        # ------------------------------------------------------------------ #
        # §10.1 Preferred-context soft sieve                                   #
        # ------------------------------------------------------------------ #

        def preferred_context_sieve(ready)
          budget     = @requirements.required_context_budget
          with_range = ready.map { |c| [c, @settings_snapshot.preferred_context_range_for(lane: c.lane)] }

          # `with_range` is an array of [candidate, range|nil] pairs. A lane with
          # no preferred range is a generalist; a lane whose range contains the
          # budget matches. The nil guard is folded into the match select on
          # purpose: `with_range.compact`/`reject { |_, r| r.nil? }` would misfire
          # (Style/CollectionCompact treats it as hash semantics) and leave nil
          # ranges in, which then crash range_contains? with `nil[:min]`.
          generalist = with_range.select { |_, r| r.nil? }.map(&:first)
          matching   = with_range.select { |_, r| r && range_contains?(r, budget) }.map(&:first)

          # Preferred range is soft: never makes any lane hard-ineligible.
          unless matching.empty?
            log.debug("[llm][ranker] action=preferred_context_sieve budget=#{budget} " \
                      "matching=#{matching.size} generalist=#{generalist.size} branch=matching")
          end
          return matching unless matching.empty?

          unless generalist.empty?
            log.debug("[llm][ranker] action=preferred_context_sieve budget=#{budget} " \
                      "matching=#{matching.size} generalist=#{generalist.size} branch=generalist")
          end
          return generalist unless generalist.empty?

          log.debug("[llm][ranker] action=preferred_context_sieve budget=#{budget} " \
                    "matching=#{matching.size} generalist=#{generalist.size} branch=ready")
          ready
        end

        # True when +budget+ falls within the (nil-open) range [min, max) —
        # the range-sieve seam is upper-exclusive (budget < max), matching
        # the baseline lane_in_range? (estimated_context < upper).
        def range_contains?(range, budget)
          (range[:min].nil? || budget >= range[:min]) &&
            (range[:max].nil? || budget < range[:max])
        end

        # ------------------------------------------------------------------ #
        # §10.2 + D17: integer weight/affinity computation                     #
        # ------------------------------------------------------------------ #

        def compute_ranked(candidates)
          # Precompute the tier boost value once; it is the same for every candidate.
          tier_max_plus_one = @settings_snapshot.tier_weights.values.max + 1

          candidates.map do |candidate|
            wi    = build_weight_inputs(candidate, tier_max_plus_one)
            base  = wi.values.reduce(1, :*)
            ppm   = compute_preference_ppm(candidate)
            eff   = base * ppm
            score = rendezvous_score(candidate)

            lane = candidate.lane
            log.debug("[llm][ranker] action=ranked " \
                      "lane=#{lane.tier}:#{lane.provider_family}:#{lane.instance_id}:#{lane_type_for(lane.operation)}:#{lane.model} " \
                      "base=#{base} ppm=#{ppm} eff=#{eff}")

            RankedCandidate.new(
              evaluation:       candidate,
              weight_inputs:    wi,
              base_weight:      base,
              preference_ppm:   ppm,
              effective_weight: eff,
              rendezvous_score: score
            )
          end
        end

        # §10.2: optionally substitute the tier weight for the preferred tier.
        # All other components are taken verbatim from the evaluation-time snapshot.
        def build_weight_inputs(candidate, tier_max_plus_one)
          base_wi = candidate.weight_inputs
          tier_w  = if @requirements.tier_preference &&
                       candidate.lane.tier == @requirements.tier_preference
                      tier_max_plus_one
                    else
                      base_wi[:tier]
                    end
          { tier: tier_w, provider: base_wi[:provider],
            instance: base_wi[:instance], model_or_offering: base_wi[:model_or_offering] }.freeze
        end

        # §10.2/D17: compute preference_ppm using integer floor division throughout.
        # Bounds: 500_000..1_500_000 (clamped as a belt-and-suspenders guard; the
        # input constraints guarantee the range without it).
        def compute_preference_ppm(candidate)
          lane_aff = compute_lane_affinity(candidate)
          raw = 1_000_000 + ((lane_aff * @requirements.affinity_strength_bps) / AFFINITY_PPM_DIVISOR)
          raw.clamp(MIN_PREFERENCE_PPM, MAX_PREFERENCE_PPM)
        end

        # Sum every matching affinity score_bps for this lane, then clamp to
        # [-10_000, 10_000] (one clamp, after summation — D17).
        def compute_lane_affinity(candidate)
          return 0 if @requirements.routing_affinities.empty?

          lane    = candidate.lane
          raw_sum = @requirements.routing_affinities.sum { |entry| affinity_score(entry, lane) }
          raw_sum.clamp(-MAX_AFFINITY_BPS, MAX_AFFINITY_BPS)
        end

        # Returns +entry[:score_bps]+ when the entry matches this lane, else 0.
        # Matching target_kinds (D17): tier, provider, instance, model, offering.
        def affinity_score(entry, lane)
          target = entry[:target].to_s
          score  = entry[:score_bps]
          case entry[:target_kind]
          when :tier     then lane.tier.to_s            == target ? score : 0
          when :provider then lane.provider_family.to_s == target ? score : 0
          when :instance then lane.instance_id.to_s     == target ? score : 0
          when :model    then lane.model.to_s            == target ? score : 0
          when :offering then lane.offering_id.to_s      == target ? score : 0
          else 0
          end
        end

        # ------------------------------------------------------------------ #
        # §10.3 Rendezvous hash (D15)                                          #
        # ------------------------------------------------------------------ #

        # SHA256("ssot-tie-v1\0" + routing_seed + "\0" + lane_id) interpreted as
        # an unsigned 256-bit big-endian Integer.
        #
        # Implementation: Digest::SHA256.digest yields 32 raw bytes; unpack1('H*')
        # produces the 64-char lowercase-hex representation; .to_i(16) converts
        # the full big-endian hex string to an Integer — equivalent to reading all
        # 32 bytes as one big-endian unsigned value.
        def rendezvous_score(candidate)
          frame = "#{RENDEZVOUS_PREFIX}#{@requirements.routing_seed}\0#{candidate.lane.lane_id}"
          Digest::SHA256.digest(frame).unpack1('H*').to_i(16)
        end

        # ------------------------------------------------------------------ #
        # §10.3 Winner selection                                                #
        # ------------------------------------------------------------------ #

        # 1. Greatest effective_weight bucket.
        # 2. Within the bucket: greatest rendezvous_score.
        # 3. Tie-break (cryptographically improbable SHA256 collision): ascending lane_id.
        def select_winner(ranked)
          max_ew = ranked.map(&:effective_weight).max
          bucket = ranked.select { |rc| rc.effective_weight == max_ew }
          winner = bucket.min_by { |rc| [-rc.rendezvous_score, rc.evaluation.lane.lane_id] }
          lane = winner.evaluation.lane
          log.debug("[llm][ranker] action=selected " \
                    "lane=#{lane.tier}:#{lane.provider_family}:#{lane.instance_id}:#{lane_type_for(lane.operation)}:#{lane.model} " \
                    "eff=#{winner.effective_weight}")
          winner
        end

        def lane_type_for(operation)
          Legion::Extensions::Llm::Taxonomies.lane_type_for(operation: operation)
        end
      end
    end
  end
end
