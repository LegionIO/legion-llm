# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module GutCheck
          include Legion::Logging::Helper
          include Steps::Logging

          def step_gut_check
            unless defined?(::Legion::Gaia::Gut) && ::Legion::Gaia::Gut.respond_to?(:check)
              log_step_debug(:gut_check, :skipped, reason: :gaia_gut_unavailable)
              return
            end

            # Gather draft stats for conflict detection.
            # This typically includes things like routing source, applied signals, and model used.
            draft_stats = {
              resolved_provider: @resolved_provider,
              resolved_model:    @resolved_model,
              applied_signals:   @applied_signals,
              tier:              @resolved_tier || @proactive_tier_assignment&.dig(:tier)
            }

            identity = @request.caller&.dig(:requested_by, :identity) || 'unknown'

            log_step_debug(:gut_check, :checking, identity: identity)

            result = ::Legion::Gaia::Gut.check(
              identity:    identity,
              draft_stats: draft_stats
            )

            if result && result[:conflict]
              log_step_info(:gut_check, :conflict_detected,
                            severity: result[:severity],
                            reason:   result[:reason])

              @warnings << "Cognitive conflict detected by GAIA Gut Check: #{result[:reason]}"

              # If the conflict is critical, we could potentially trigger an escalation
              # or mark the response as suspect. For now, we follow the requirement to detect.
              @audit[:'delivery:gut_check'] = {
                outcome:   :conflict,
                severity:  result[:severity],
                reason:    result[:reason],
                timestamp: Time.now
              }
            else
              log_step_debug(:gut_check, :no_conflict)
            end
          rescue StandardError => e
            @warnings << "Gut check error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.gut_check')
          end
        end
      end
    end
  end
end
