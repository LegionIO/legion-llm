# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Steps
        module GaiaAdvisory
          def step_gaia_advisory
            unless defined?(::Legion::Gaia) && ::Legion::Gaia.started?
              @warnings << 'GAIA unavailable for pre-request shaping'
              return
            end

            advisory = ::Legion::Gaia.advise(
              conversation_id: @request.conversation_id,
              messages:        @request.messages,
              caller:          @request.caller
            )

            return if advisory.nil? || advisory.empty?

            @enrichments['gaia:advisory'] = {
              content:   advisory_summary(advisory),
              data:      advisory,
              timestamp: Time.now
            }

            if advisory[:system_prompt]
              @enrichments['gaia:system_prompt'] = {
                content:   advisory[:system_prompt],
                timestamp: Time.now
              }
            end

            if advisory[:routing_hint]
              @enrichments['gaia:routing_hint'] = {
                data:      advisory[:routing_hint],
                timestamp: Time.now
              }
            end

            @timeline.record(
              category: :enrichment, key: 'gaia:advisory',
              direction: :inbound, detail: advisory_summary(advisory),
              from: 'gaia', to: 'pipeline'
            )
          rescue StandardError => e
            @warnings << "GAIA advisory error: #{e.message}"
          end

          private

          def advisory_summary(advisory)
            parts = []
            parts << "valence:#{advisory[:valence]&.first}" if advisory[:valence]
            parts << "tools:#{advisory[:tool_hint]&.length}" if advisory[:tool_hint]
            parts << "suppress:#{advisory[:suppress]&.join(',')}" if advisory[:suppress]
            parts.empty? ? 'no enrichment' : parts.join(', ')
          end
        end
      end
    end
  end
end
