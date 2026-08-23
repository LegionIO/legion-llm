# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Routing
      # Soft ordering of eligible candidates: preferred-context band,
      # weight x affinity, rendezvous tie-break, winner selection.
      module Rank
        include Legion::Logging::Helper

        def rank(**); end
        def rank_band_partition(**); end
        def rank_preferred_context_match(**); end
        def rank_compute(**); end
        def rank_preference_ppm(**); end
        def rank_lane_affinity(**); end
        def rank_affinity_score(**); end
        def rank_rendezvous_score(**); end
        def rank_select_winner(**); end
      end
    end
  end
end
