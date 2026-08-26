# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Routing
      # Fleet routing concern — stateless mixin included into the Router class.
      # Provides fleet-dispatch enablement check and fleet-lane qualification.
      module Fleet
        include Legion::Logging::Helper

        # Whether fleet dispatch is globally enabled. Default-on; returns false
        # only when the operator has explicitly disabled it. Replaces the legacy
        # read at inference/route_attempts.rb ([:llm][:fleet][:dispatch][:enabled]),
        # now namespaced under [:llm][:router][:fleet_dispatch_enabled].
        def fleet_enabled?(**)
          Legion::Settings[:llm][:router][:fleet_dispatch_enabled] != false
        end

        # Whether +lane+ qualifies as a dispatchable fleet lane: the lane must
        # be tier :fleet AND carry the supported fleet execution contract.
        # Self-contained (does NOT call Filter#filter_fleet) so Fleet stays an
        # independently-testable mixin — this is exactly the condition
        # filter_fleet collapses to for its :supported verdict.
        def fleet_lane?(lane:, **)
          lane.tier == :fleet && lane.metadata[:fleet_execution_contract] == 'exact_offering_v1'
        end
      end
    end
  end
end
