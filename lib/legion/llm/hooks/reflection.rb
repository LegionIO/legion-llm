# frozen_string_literal: true

require 'legion/logging/helper'
require_relative '../publisher_identity'
module Legion
  module LLM
    module Hooks
      # Extracts learnings from conversation completions and publishes them
      # for Apollo knowledge ingestion. Runs as an after_chat hook.
      #
      # Extracted knowledge types:
      # - Decisions: technical choices made during conversation
      # - Patterns: recurring code patterns or architectural approaches
      # - Facts: concrete facts about systems, APIs, or configurations
      #
      # Only triggers on substantive responses (>200 chars) to avoid noise.
      module Reflection
        extend Legion::Logging::Helper

        @last_extraction = nil
        @extractions = []
        @mutex = Mutex.new

        module_function

        def install
          Legion::LLM::Hooks.after_chat do |response:, messages:, model:, **|
            extract_async(response, messages, model)
            nil
          end
        end

        def extract_async(response, messages, model)
          return unless should_extract?(response)

          Legion::LLM::Inference::Background.post(workload: :reflection) do
            extract(response, messages, model)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'llm.hooks.reflection.extract_async', model: model)
            log.debug("[llm][reflection] extract_async_failed model=#{model} error=#{e.message}")
          end
        end

        def extract(response, messages, model)
          content = extract_content(response)
          return if content.nil? || content.length < Legion::Settings[:llm][:reflection][:min_response_chars]

          @mutex.synchronize do
            return if @last_extraction && (Time.now - @last_extraction) < Legion::Settings[:llm][:reflection][:cooldown_seconds]

            @last_extraction = Time.now
          end

          entries = analyze_for_knowledge(content, messages)
          return if entries.empty?

          entries.each { |entry| publish_entry(entry, model) }
          @mutex.synchronize { @extractions.concat(entries) }

          log.info("[llm][reflection] extracted model=#{model} count=#{entries.size}")
        end

        def analyze_for_knowledge(content, messages)
          entries = []

          entries.concat(extract_decisions(content))
          entries.concat(extract_patterns(content))
          entries.concat(extract_facts(content))

          context = conversation_context(messages)
          entries.each { |e| e[:context] = context }

          entries
        end

        def extract_decisions(content)
          decision_markers = [
            /(?:decided|choosing|chose|going with|opted for|will use|should use)\s+(.{10,200})/i,
            /(?:the (?:best|right|correct) (?:approach|solution|way))\s+(?:is|would be)\s+(.{10,200})/i
          ]

          entries = []
          decision_markers.each do |pattern|
            content.scan(pattern) do |match|
              text = match[0].strip
              text = truncate(text, Legion::Settings[:llm][:reflection][:max_extract_chars])
              entries << {
                type:         :decision,
                content:      text,
                confidence:   Legion::Settings[:llm][:reflection][:confidence][:decision],
                source:       'reflection',
                extracted_at: Time.now.iso8601
              }
            end
          end
          entries.first(Legion::Settings[:llm][:reflection][:max_entries][:decision])
        end

        def extract_patterns(content)
          pattern_markers = [
            /(?:pattern|convention|idiom|approach)(?:\s+(?:is|for|to))?\s*:?\s*(.{10,200})/i,
            /(?:always|never|typically|usually)\s+(.{10,200})/i
          ]

          entries = []
          pattern_markers.each do |pattern|
            content.scan(pattern) do |match|
              text = match[0].strip
              text = truncate(text, Legion::Settings[:llm][:reflection][:max_extract_chars])
              entries << {
                type:         :pattern,
                content:      text,
                confidence:   Legion::Settings[:llm][:reflection][:confidence][:pattern],
                source:       'reflection',
                extracted_at: Time.now.iso8601
              }
            end
          end
          entries.first(Legion::Settings[:llm][:reflection][:max_entries][:pattern])
        end

        def extract_facts(content)
          fact_markers = [
            /(?:the (?:default|setting|value|port|path|endpoint)\s+(?:is|for))\s+(.{5,200})/i,
            /(?:requires?|depends? on|needs?)\s+(.{5,200})/i,
            /(?:version|v)\s*(\d+\.\d+[\w.-]*)/i
          ]

          entries = []
          fact_markers.each do |pattern|
            content.scan(pattern) do |match|
              text = match[0].strip
              text = truncate(text, Legion::Settings[:llm][:reflection][:max_extract_chars])
              entries << {
                type:         :fact,
                content:      text,
                confidence:   Legion::Settings[:llm][:reflection][:confidence][:fact],
                source:       'reflection',
                extracted_at: Time.now.iso8601
              }
            end
          end
          entries.first(Legion::Settings[:llm][:reflection][:max_entries][:fact])
        end

        def conversation_context(messages)
          return nil if messages.nil? || messages.empty?

          user_messages = messages.select { |m| m[:role].to_s == 'user' }
          return nil if user_messages.empty?

          first = user_messages.first[:content].to_s
          truncate(first, Legion::Settings[:llm][:reflection][:context_chars])
        end

        def publish_entry(entry, model)
          if apollo_transport?
            Legion::Transport.publish(
              'lex.apollo.ingest',
              Legion::JSON.dump({
                                  content:          entry[:content],
                                  content_type:     entry[:type].to_s,
                                  knowledge_domain: 'reflection',
                                  confidence:       entry[:confidence],
                                  source_agent:     "llm:#{model}",
                                  metadata:         {
                                    context:      entry[:context],
                                    source:       'reflection_hook',
                                    submitted_by: Legion::LLM::PublisherIdentity.requested_by
                                  }
                                })
            )
            log.info("[llm][reflection] published via=transport model=#{model} type=#{entry[:type]}")
          elsif apollo_direct?
            Legion::Extensions::Apollo::Runners::Request.ingest(
              content:          entry[:content],
              content_type:     entry[:type].to_s,
              knowledge_domain: 'reflection',
              confidence:       entry[:confidence],
              source_agent:     "llm:#{model}",
              source_channel:   'reflection_hook'
            )
            log.info("[llm][reflection] published via=direct model=#{model} type=#{entry[:type]}")
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.hooks.reflection.publish_entry', model: model)
          log.error("[llm][reflection] publish_failed model=#{model} type=#{entry[:type]} error=#{e.message}")
        end

        def should_extract?(response)
          content = extract_content(response)
          !content.nil? && content.length >= Legion::Settings[:llm][:reflection][:min_response_chars]
        end

        def extract_content(response)
          if response.respond_to?(:content)
            response.content.to_s
          elsif response.is_a?(Hash)
            (response[:content] || response[:text]).to_s
          end
        end

        def summary
          @mutex.synchronize do
            {
              total_extractions: @extractions.size,
              last_extraction:   @last_extraction&.iso8601,
              by_type:           @extractions.group_by { |e| e[:type] }.transform_values(&:size),
              recent:            @extractions.last(Legion::Settings[:llm][:reflection][:recent_entries]).map { |e| { type: e[:type], content: truncate(e[:content], Legion::Settings[:llm][:reflection][:recent_preview_chars]) } }
            }
          end
        end

        def reset!
          @mutex.synchronize do
            @extractions = []
            @last_extraction = nil
          end
        end

        def truncate(str, max)
          str.length > max ? "#{str[0, max]}..." : str
        end
        private_class_method :truncate

        def apollo_transport?
          Legion::Settings.dig(:transport, :connected) == true
        end
        private_class_method :apollo_transport?

        def apollo_direct?
          defined?(Legion::Extensions::Apollo::Runners::Request)
        end
        private_class_method :apollo_direct?
      end
    end
  end
end
