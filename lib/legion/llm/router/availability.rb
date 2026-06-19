# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Router
      module Availability
        extend Legion::Logging::Helper

        module_function

        # Lane-based rejection reason for request_lane consumers (P4+).
        # Reads lane[:health] directly — no Resolution object, no Inventory call.
        def lane_rejection_reason(lane:, **)
          return :policy_denied if lane[:health][:denied]
          return :circuit_open  if lane[:health][:circuit_state] == :open
          return :unavailable   if lane[:health][:available] == false

          nil
        end
      end
    end
  end
end
