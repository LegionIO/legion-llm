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

            enrich_advisory_with_partner_context(advisory)

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

          # Exposed as a public method so specs can stub it on instances.
          def build_partner_context(identity)
            return default_partner_context unless apollo_local_available?

            entries = ::Legion::Apollo::Local.query(
              text:  identity,
              tags:  ['partner'],
              limit: 5
            )

            results = entries.is_a?(Hash) ? (entries[:results] || []) : Array(entries)

            {
              standing:            extract_standing(results),
              compatibility:       extract_compatibility(results),
              recent_sentiment:    extract_sentiment(results),
              interaction_pattern: extract_interaction_pattern(results)
            }
          rescue StandardError => e
            Legion::Logging.debug "[GaiaAdvisory] build_partner_context error: #{e.message}" if defined?(Legion::Logging)
            nil
          end

          private

          def advisory_summary(advisory)
            parts = []
            parts << "valence:#{advisory[:valence]&.first}" if advisory[:valence]
            parts << "tools:#{advisory[:tool_hint]&.length}" if advisory[:tool_hint]
            parts << "suppress:#{advisory[:suppress]&.join(',')}" if advisory[:suppress]
            parts.empty? ? 'no enrichment' : parts.join(', ')
          end

          def enrich_advisory_with_partner_context(advisory)
            return unless defined?(::Legion::Gaia::BondRegistry)

            identity = @request.caller&.dig(:requested_by, :identity)
            return unless identity
            return unless ::Legion::Gaia::BondRegistry.partner?(identity)

            partner_ctx = build_partner_context(identity)
            advisory[:partner_context] = partner_ctx if partner_ctx
          rescue StandardError => e
            Legion::Logging.debug "[GaiaAdvisory] partner context error: #{e.message}" if defined?(Legion::Logging)
          end

          def apollo_local_available?
            defined?(::Legion::Apollo::Local) && ::Legion::Apollo::Local.started?
          rescue StandardError
            false
          end

          def default_partner_context
            {
              standing:            :unknown,
              compatibility:       nil,
              recent_sentiment:    :neutral,
              interaction_pattern: :unknown
            }
          end

          def extract_standing(results)
            entry = results.find { |r| r[:content].to_s.match?(/standing/i) }
            return :unknown unless entry

            content = entry[:content].to_s
            if content.match?(/good|trusted|positive/i)
              :good
            elsif content.match?(/poor|untrusted|negative/i)
              :poor
            else
              :neutral
            end
          end

          def extract_compatibility(results)
            entry = results.find { |r| r[:content].to_s.match?(/compat/i) }
            return nil unless entry

            match = entry[:content].to_s.match(/(\d+(?:\.\d+)?)/)
            match ? match[1].to_f : nil
          end

          def extract_sentiment(results)
            entry = results.find { |r| r[:content].to_s.match?(/sentiment|empathy|affect/i) }
            return :neutral unless entry

            content = entry[:content].to_s
            if content.match?(/positive|happy|pleasant/i)
              :positive
            elsif content.match?(/negative|unhappy|tense/i)
              :negative
            else
              :neutral
            end
          end

          def extract_interaction_pattern(results)
            entry = results.find { |r| r[:content].to_s.match?(/interaction|memory|trace/i) }
            return :unknown unless entry

            content = entry[:content].to_s
            if content.match?(/frequent|regular|daily/i)
              :frequent
            elsif content.match?(/occasional|sometimes/i)
              :occasional
            else
              :infrequent
            end
          end
        end
      end
    end
  end
end
