# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'logging'

module Legion
  module LLM
    module Inference
      module Steps
        module RagContext
          include Legion::Logging::Helper
          include Steps::Logging

          def step_rag_context
            unless rag_enabled?
              log_step_debug(:rag_context, :skipped, reason: :disabled)
              return
            end
            unless substantive_query?
              log_step_debug(:rag_context, :skipped, reason: :non_substantive_query)
              return
            end
            unless apollo_available_or_warn?
              log_step_debug(:rag_context, :skipped, reason: :apollo_unavailable)
              return
            end

            utilization = estimate_utilization
            strategy = select_context_strategy(utilization: utilization)
            if strategy == :none
              log_step_debug(:rag_context, :skipped, reason: :context_window_high, utilization: utilization.round(3))
              return
            end

            query = extract_query
            start_time = Time.now
            log_step_debug(:rag_context, :retrieve, strategy: strategy, query_chars: query.to_s.length)
            result = apollo_retrieve(query: query, strategy: strategy)
            record_rag_enrichment(result, strategy)
            record_rag_timeline(result, strategy, start_time)
            @applied_signals[:envelope_keys] << "rag_context:#{strategy}" if @applied_signals.is_a?(Hash)
          rescue StandardError => e
            @warnings << "RAG context error: #{e.message}"
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.rag_context')
          end

          private

          def rag_enabled?
            Legion::Settings[:llm][:rag][:enabled] == true
          end

          def substantive_query?
            query = extract_query
            return false if query.nil? || query.empty?

            auto_strategy = @request.context_strategy.nil? || @request.context_strategy == :auto
            log.unknown auto_strategy
            return true unless auto_strategy

            !trivial_query?(query)
          end

          def apollo_available_or_warn?
            return true if apollo_available?

            @warnings << 'Apollo unavailable for RAG context retrieval'
            log_step_debug(:rag_context, :apollo_unavailable)
            false
          end

          def record_rag_enrichment(result, strategy)
            entries = result[:entries] || []
            unless result && result[:success] && entries.any?
              log_step_debug(:rag_context, :no_context_added, strategy: strategy)
              @context_accounting&.dig(:component_status)&.[]=(:rag, :observed)
              return
            end
            total_chars = entries.sum { |e| (e[:content] || e['content']).to_s.length }
            log_step_info(:rag_context, :context_injected, strategy: strategy, entry_count: entries.size, total_chars: total_chars)
            log.unknown entries

            scores = entries.filter_map { |e| e[:confidence] || e[:distance] }.map { |s| s.is_a?(Numeric) ? s.round(3) : s }
            log.debug(
              "[llm][steps][rag_context] action=results_scored request_id=#{@request&.id || 'unknown'} " \
              "strategy=#{strategy} count=#{entries.size} scores=#{scores.inspect} " \
              "types=#{entries.map { |e| e[:content_type] }.compact.tally.inspect}"
            )

            if @context_accounting
              rag_text = entries.map { |e| "[#{e[:content_type] || e['content_type']}] #{e[:content] || e['content']}" }.join("\n")
              rag_tokens = ContextAccounting.estimate_text_tokens(rag_text)
              @context_accounting[:tokens][:rag_injected_estimated_tokens] = rag_tokens
              @context_accounting[:counts][:rag_entry_count] = entries.size
              @context_accounting[:component_status][:rag] = :observed
              @context_accounting[:events] << ContextAccounting.event(
                event_type:    :rag_injected,
                component:     :rag,
                before_tokens: 0,
                after_tokens:  rag_tokens,
                before_count:  0,
                after_count:   entries.size,
                metadata:      { strategy: strategy }
              )
            end

            @enrichments['rag:context_retrieval'] = {
              content:   "#{result[:count]} entries retrieved via #{strategy}",
              data:      { entries: entries, strategy: strategy, count: result[:count] },
              timestamp: Time.now
            }
            log_step_info(:rag_context, :context_added, strategy: strategy, entry_count: entries.size)
          end

          def record_rag_timeline(result, strategy, start_time)
            count = result[:count] || 0
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
            if explicit && explicit != :auto
              log_step_info(:rag_context, :strategy_explicit, strategy: explicit)
              return explicit
            end

            skip_threshold    = Legion::Settings[:llm][:rag][:utilization_skip_threshold]
            compact_threshold = Legion::Settings[:llm][:rag][:utilization_compact_threshold]

            strategy = if utilization >= skip_threshold
                         :none
                       elsif utilization >= compact_threshold
                         :rag_compact
                       else
                         :rag
                       end
            log_step_info(:rag_context, :strategy_selected, strategy: strategy, utilization: utilization.round(3),
                                                            skip_threshold: skip_threshold, compact_threshold: compact_threshold)
            strategy
          end

          def estimate_utilization
            return 0.0 if @request.tokens[:max].nil? || @request.tokens[:max].zero?

            message_tokens = @request.messages.sum { |m| content_text(message_content(m)).length / 4 }
            message_tokens.to_f / @request.tokens[:max]
          end

          def trivial_query?(query)
            query = content_text(query)
            max_chars = Legion::Settings[:llm][:rag][:trivial_max_chars]
            patterns = Legion::Settings[:llm][:rag][:trivial_patterns]

            normalized = query.strip.downcase.gsub(/[^a-z0-9\s]/, '')
            return true if patterns.any? { |p| normalized == p }
            return true if query.length <= max_chars && normalized.split.length <= 1

            false
          end

          def apollo_available?
            return true if defined?(::Legion::Extensions::Apollo::Runners::Knowledge)

            defined?(::Legion::Apollo) && ::Legion::Apollo.started?
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.rag_context.apollo_available')
            false
          end

          def apollo_retrieve(query:, strategy:)
            full_limit    = Legion::Settings[:llm][:rag][:full_limit]
            compact_limit = Legion::Settings[:llm][:rag][:compact_limit]
            confidence    = Legion::Settings[:llm][:rag][:min_confidence]
            limit = apply_gaia_context_limit(strategy == :rag_compact ? compact_limit : full_limit,
                                             strategy: strategy)
            log_step_debug(:rag_context, :apollo_query, strategy: strategy, limit: limit, min_confidence: confidence)

            general = apollo_retrieve_general(query: query, limit: limit, confidence: confidence)
            history = apollo_retrieve_conversation_history(query: query, limit: limit, confidence: confidence)
            result = merge_apollo_results(general, history)
            filter_excluded_source_agents(result)
          end

          def filter_excluded_source_agents(result)
            excluded = Array(Legion::Settings[:llm][:rag][:exclude_source_agents])
            return result if excluded.empty?

            entries = Array(result[:entries])
            filtered = entries.reject { |e| excluded.include?(e[:source_agent].to_s) }
            if filtered.size < entries.size
              log.debug(
                "[llm][steps][rag_context] action=source_agent_filter excluded=#{entries.size - filtered.size} " \
                "remaining=#{filtered.size} agents=#{excluded.inspect}"
              )
            end
            result.merge(entries: filtered, count: filtered.size)
          end

          def apollo_retrieve_general(query:, limit:, confidence:)
            if defined?(::Legion::Extensions::Apollo::Runners::Knowledge)
              ::Legion::Extensions::Apollo::Runners::Knowledge.retrieve_relevant(
                query: query, limit: limit, min_confidence: confidence
              )
            elsif defined?(::Legion::Apollo)
              begin
                if ::Legion::Apollo.started?
                  ::Legion::Apollo.retrieve(text: query, limit: limit, scope: :all)
                else
                  log_step_debug(:rag_context, :apollo_query_skipped, reason: :not_started)
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

          def apollo_retrieve_conversation_history(query:, limit:, confidence:)
            return empty_apollo_result unless conversation_history_retrieval_enabled?

            conversation_id = @request.conversation_id
            return empty_apollo_result if conversation_id.to_s.empty?

            tags = ['llm_conversation_history', "conversation:#{conversation_id}"]
            log_step_debug(:rag_context, :apollo_history_query, limit: limit, tag_count: tags.size)
            if defined?(::Legion::Extensions::Apollo::Runners::Knowledge)
              ::Legion::Extensions::Apollo::Runners::Knowledge.retrieve_relevant(
                query:          query,
                limit:          limit,
                min_confidence: confidence,
                tags:           tags,
                domain:         'conversation_history'
              )
            elsif defined?(::Legion::Apollo) && ::Legion::Apollo.started?
              ::Legion::Apollo.retrieve(
                text:   query,
                limit:  limit,
                scope:  :all,
                tags:   tags,
                domain: 'conversation_history'
              )
            else
              empty_apollo_result
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.pipeline.steps.rag_context.apollo_history_retrieve',
                                conversation_id: conversation_id)
            empty_apollo_result
          end

          def conversation_history_retrieval_enabled?
            Legion::Settings[:llm][:rag][:conversation_history_enabled] == true
          end

          def merge_apollo_results(*results)
            entries = results.flat_map { |result| apollo_result_entries(result) }
            {
              success: entries.any? || results.any? { |result| result[:success] },
              entries: entries,
              count:   entries.size
            }
          end

          def apollo_result_entries(result)
            return [] if result.nil?

            if result.respond_to?(:key?)
              Array(result[:entries] || [])
            else
              Array(result)
            end
          end

          def empty_apollo_result
            { success: true, entries: [], count: 0 }
          end

          def extract_query
            @request.messages.select { |m| m[:role].to_s == 'user' }
                    .then { |messages| content_text(message_content(messages.last)) }
          end

          def message_content(message)
            message[:content]
          end

          def content_text(content)
            case content
            when nil
              ''
            when String
              content
            when Array
              content.filter_map { |entry| content_text(entry) }.join
            when Hash
              type = content[:type] || content['type']
              return '' unless type.nil? || type.to_s == 'text'

              text = if content.key?(:text) || content.key?('text')
                       content[:text] || content['text']
                     else
                       content[:content] || content['content']
                     end
              content_text(text)
            else
              content.respond_to?(:text) ? content.text.to_s : content.to_s
            end
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
            return nil if value.nil?
            return nil if value.respond_to?(:empty?) && value.empty?

            integer = Integer(value)
            integer.positive? ? integer : nil
          rescue ArgumentError, TypeError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.pipeline.steps.rag_context.positive_integer')
            nil
          end
        end
      end
    end
  end
end
