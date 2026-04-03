# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Pipeline
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
            @rag_settings ||= if defined?(Legion::Settings) && !Legion::Settings[:llm].nil?
                                Legion::Settings[:llm][:rag] || {}
                              else
                                {}
                              end
          end

          def rag_enabled?
            rag_settings.fetch(:enabled, true)
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
            return unless result && result[:success] && result[:entries]&.any?

            @enrichments['rag:context_retrieval'] = {
              content:   "#{result[:count]} entries retrieved via #{strategy}",
              data:      { entries: result[:entries], strategy: strategy, count: result[:count] },
              timestamp: Time.now
            }
          end

          def record_rag_timeline(result, strategy, start_time)
            @timeline.record(
              category: :enrichment, key: 'rag:context_retrieval',
              direction: :inbound,
              detail: "#{result&.dig(:count) || 0} entries via #{strategy}",
              from: 'apollo', to: 'pipeline',
              duration_ms: ((Time.now - start_time) * 1000).to_i
            )
          end

          def select_context_strategy(utilization:)
            explicit = @request.context_strategy
            return explicit if explicit && explicit != :auto

            skip_threshold    = rag_settings.fetch(:utilization_skip_threshold, 0.9)
            compact_threshold = rag_settings.fetch(:utilization_compact_threshold, 0.7)

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
            max_chars = rag_settings.fetch(:trivial_max_chars, 20)
            patterns  = rag_settings.fetch(:trivial_patterns, [])

            return false if query.length > max_chars

            normalized = query.strip.downcase.gsub(/[^a-z0-9\s]/, '')
            patterns.any? { |p| normalized == p }
          end

          def apollo_available?
            return true if defined?(::Legion::Extensions::Apollo::Runners::Knowledge)

            defined?(::Legion::Apollo) && ::Legion::Apollo.started?
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'llm.pipeline.steps.rag_context.apollo_available')
            false
          end

          def apollo_retrieve(query:, strategy:)
            full_limit    = rag_settings.fetch(:full_limit, 10)
            compact_limit = rag_settings.fetch(:compact_limit, 5)
            confidence    = rag_settings.fetch(:min_confidence, 0.5)
            limit = strategy == :rag_compact ? compact_limit : full_limit

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
                handle_exception(e, level: :debug, operation: 'llm.pipeline.steps.rag_context.apollo_retrieve')
                []
              end
            else
              []
            end
          end

          def extract_query
            @request.messages.select { |m| m[:role] == :user }
                             .last&.dig(:content)
          end
        end
      end
    end
  end
end
