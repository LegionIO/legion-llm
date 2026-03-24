# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      module Steps
        module RagContext
          def step_rag_context
            strategy = select_context_strategy(utilization: estimate_utilization)
            return if strategy == :none || strategy == :full

            unless apollo_available?
              @warnings << 'Apollo unavailable for RAG context retrieval'
              return
            end

            query = extract_query
            return if query.nil? || query.empty?

            start_time = Time.now
            result = apollo_retrieve(query: query, strategy: strategy)

            if result && result[:success] && result[:entries]&.any?
              @enrichments['rag:context_retrieval'] = {
                content: "#{result[:count]} entries retrieved via #{strategy}",
                data: {
                  entries: result[:entries],
                  strategy: strategy,
                  count: result[:count]
                },
                timestamp: Time.now
              }
            end

            @timeline.record(
              category: :enrichment, key: 'rag:context_retrieval',
              direction: :inbound,
              detail: "#{result&.dig(:count) || 0} entries via #{strategy}",
              from: 'apollo', to: 'pipeline',
              duration_ms: ((Time.now - start_time) * 1000).to_i
            )
          rescue StandardError => e
            @warnings << "RAG context error: #{e.message}"
          end

          private

          def select_context_strategy(utilization:)
            explicit = @request.context_strategy
            return explicit if explicit && explicit != :auto

            case utilization
            when 0...0.3    then :full
            when 0.3...0.8  then :rag_hybrid
            when 0.8...0.95 then :rag
            else                 :rag
            end
          end

          def estimate_utilization
            return 0.0 if @request.tokens[:max].nil? || @request.tokens[:max].zero?

            message_tokens = @request.messages.sum { |m| (m[:content]&.length || 0) / 4 }
            message_tokens.to_f / @request.tokens[:max]
          end

          def apollo_available?
            defined?(::Legion::Extensions::Apollo::Runners::Knowledge)
          end

          def apollo_retrieve(query:, strategy:)
            opts = { query: query, limit: 10, min_confidence: 0.5 }
            opts[:limit] = 5 if strategy == :rag_hybrid

            ::Legion::Extensions::Apollo::Runners::Knowledge.retrieve_relevant(**opts)
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
