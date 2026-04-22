# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Inference
      module Steps
        module GaiaAdvisory
          include Legion::Logging::Helper

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

            calibration_weights = fetch_calibration_weights
            advisory[:calibration_weights] = calibration_weights if calibration_weights

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

            record_advisory_meta_to_gaia(advisory)
          rescue StandardError => e
            @warnings << "GAIA advisory error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.gaia_advisory')
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
            handle_exception(e, level: :debug)
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
            handle_exception(e, level: :debug)
          end

          def apollo_local_available?
            defined?(::Legion::Apollo::Local) && ::Legion::Apollo::Local.started?
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.pipeline.steps.gaia_advisory.apollo_local_available')
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

          def fetch_calibration_weights
            return nil unless apollo_local_available?

            result = ::Legion::Apollo::Local.query(
              text: 'bond calibration weights',
              tags: %w[bond calibration weights]
            )
            return nil unless result[:success] && result[:results]&.any?

            raw = ::JSON.parse(result[:results].first[:content])
            raw['weights']
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.pipeline.steps.gaia_advisory.fetch_partner_weights')
            nil
          end

          def record_advisory_meta_to_gaia(advisory)
            return unless defined?(::Legion::Gaia) && ::Legion::Gaia.respond_to?(:record_advisory_meta)
            return unless advisory[:partner_context]

            advisory_id = SecureRandom.uuid
            advisory_types = classify_advisory_types(advisory)

            ::Legion::Gaia.record_advisory_meta(
              advisory_id:    advisory_id,
              advisory_types: advisory_types
            )
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.pipeline.steps.gaia_advisory.record_meta')
            nil
          end

          def classify_advisory_types(advisory)
            types = []
            pc = advisory[:partner_context]
            return ['partner_hint'] unless pc

            types << 'partner_hint' if pc
            types << 'context_injection' if advisory[:context_window]
            types << 'tone_adjustment' if pc[:recent_sentiment] && pc[:recent_sentiment] != :neutral
            types << 'verbosity_adjustment' if pc[:interaction_pattern] && pc[:interaction_pattern] != :unknown
            types << 'format_adjustment' if pc[:compatibility]
            types.empty? ? ['partner_hint'] : types
          end
        end
      end
    end
  end
end
