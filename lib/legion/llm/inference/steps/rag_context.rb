# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      module Steps
        module RagContext
          include Legion::Logging::Helper

          def step_rag_context
            return unless rag_enabled?
            return unless substantive_query?
            return unless apollo_available_or_warn?

            strategy = select_context_strategy(utilization: estimate_utilization)
            return if strategy == :none

            query = extract_query
            start_time = Time.now
            result = apollo_retrieve(query: query, strategy: strategy)
            record_rag_enrichment(result, strategy)
            record_rag_timeline(result, strategy, start_time)
          rescue StandardError => e
            @warnings << "RAG context error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.rag_context')
          end

          private

          def rag_settings
            @rag_settings ||= settings_value(:rag, default: {})
          end

          def rag_setting(key, default = nil)
            Legion::LLM::Settings.config_value(rag_settings, key, default)
          end

          def settings_value(*keys, default: nil)
            Legion::LLM::Settings.value(*keys, default: default)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.steps.rag_context.settings', keys: keys)
            default
          end

          def rag_enabled?
            rag_setting(:enabled, true)
          end

          def substantive_query?
            query = extract_query
            return false if query.nil? || query.empty?

            auto_strategy = @request.context_strategy.nil? || @request.context_strategy == :auto
            return true unless auto_strategy

            !trivial_query?(query)
          end

          def apollo_available_or_warn?
            return true if apollo_available?

            @warnings << 'Apollo unavailable for RAG context retrieval'
            false
          end

          def record_rag_enrichment(result, strategy)
            entries = Legion::LLM::Settings.config_value(result, :entries, [])
            return unless result && Legion::LLM::Settings.config_value(result, :success) && entries.any?

            @enrichments['rag:context_retrieval'] = {
              content:   "#{Legion::LLM::Settings.config_value(result, :count)} entries retrieved via #{strategy}",
              data:      { entries: entries, strategy: strategy, count: Legion::LLM::Settings.config_value(result, :count) },
              timestamp: Time.now
            }
          end

          def record_rag_timeline(result, strategy, start_time)
            count = Legion::LLM::Settings.config_value(result, :count, 0)
            @timeline.record(
              category: :enrichment, key: 'rag:context_retrieval',
              direction: :inbound,
              detail: "#{count} entries via #{strategy}",
              from: 'apollo', to: 'pipeline',
              duration_ms: ((Time.now - start_time) * 1000).to_i
            )
          end

          def select_context_strategy(utilization:)
            explicit = @request.context_strategy
            return explicit if explicit && explicit != :auto

            skip_threshold    = rag_setting(:utilization_skip_threshold, 0.9)
            compact_threshold = rag_setting(:utilization_compact_threshold, 0.7)

            if utilization >= skip_threshold
              :none
            elsif utilization >= compact_threshold
              :rag_compact
            else
              :rag
            end
          end

          def estimate_utilization
            return 0.0 if @request.tokens[:max].nil? || @request.tokens[:max].zero?

            message_tokens = @request.messages.sum { |m| (m[:content]&.length || 0) / 4 }
            message_tokens.to_f / @request.tokens[:max]
          end

          def trivial_query?(query)
            max_chars = rag_setting(:trivial_max_chars, 20)
            patterns  = rag_setting(:trivial_patterns, [])

            return false if query.length > max_chars

            normalized = query.strip.downcase.gsub(/[^a-z0-9\s]/, '')
            patterns.any? { |p| normalized == p }
          end

          def apollo_available?
            return true if defined?(::Legion::Extensions::Apollo::Runners::Knowledge)

            defined?(::Legion::Apollo) && ::Legion::Apollo.started?
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.rag_context.apollo_available')
            false
          end

          def apollo_retrieve(query:, strategy:)
            full_limit    = rag_setting(:full_limit, 10)
            compact_limit = rag_setting(:compact_limit, 5)
            confidence    = rag_setting(:min_confidence, 0.5)
            limit = apply_gaia_context_limit(strategy == :rag_compact ? compact_limit : full_limit,
                                             strategy: strategy)

            if defined?(::Legion::Extensions::Apollo::Runners::Knowledge)
              ::Legion::Extensions::Apollo::Runners::Knowledge.retrieve_relevant(
                query: query, limit: limit, min_confidence: confidence
              )
            elsif defined?(::Legion::Apollo)
              begin
                if ::Legion::Apollo.started?
                  ::Legion::Apollo.retrieve(text: query, limit: limit, scope: :all)
                else
                  []
                end
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.rag_context.apollo_retrieve')
                []
              end
            else
              []
            end
          end

          def extract_query
            @request.messages.select { |m| Legion::LLM::Settings.config_value(m, :role).to_s == 'user' }
                             .then { |messages| Legion::LLM::Settings.config_value(messages.last, :content) }
          end

          def apply_gaia_context_limit(limit, strategy:)
            gaia_limit = gaia_context_limit(strategy: strategy)
            return limit unless gaia_limit&.positive?

            [limit, gaia_limit].min
          end

          def gaia_context_limit(strategy:)
            window = gaia_advisory_value(:context_window)
            case window
            when Hash
              value = window[strategy] || window[strategy.to_s] ||
                      window[:limit] || window['limit'] ||
                      window[:max_entries] || window['max_entries'] ||
                      window[:context_limit] || window['context_limit']
              positive_integer(value)
            when Array
              window.size.positive? ? window.size : nil
            else
              positive_integer(window)
            end
          end

          def gaia_advisory_value(key)
            enrichment = @enrichments['gaia:advisory']
            return nil unless enrichment.respond_to?(:key?)

            data = enrichment[:data] || enrichment['data'] || {}
            return nil unless data.respond_to?(:key?)

            data[key] || data[key.to_s]
          end

          def positive_integer(value)
            integer = Integer(value)
            integer.positive? ? integer : nil
          rescue ArgumentError, TypeError
            nil
          end
        end
      end
    end
  end
end
