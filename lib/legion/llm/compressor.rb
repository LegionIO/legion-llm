# frozen_string_literal: true

require 'legion/logging/helper'
module Legion
  module LLM
    module Compressor
      extend Legion::Logging::Helper
      NONE       = 0
      LIGHT      = 1
      MODERATE   = 2
      AGGRESSIVE = 3

      LEVEL_WORDS = {
        1 => %w[a an the just very really basically actually simply quite rather somewhat],
        2 => %w[however moreover furthermore additionally consequently therefore thus hence
                meanwhile nevertheless nonetheless accordingly indeed certainly],
        3 => %w[also then still even already yet again please note that]
      }.freeze

      SUMMARIZE_PROMPT = <<~PROMPT
        Summarize this conversation concisely. Preserve:
        - Key decisions and conclusions
        - Code snippets and file paths
        - Action items and next steps
        - Technical details that would be needed to continue the conversation

        Omit pleasantries, repetition, and verbose explanations.
        Return only the summary, no preamble.
      PROMPT

      class << self
        def compress(text, level: LIGHT)
          return text if text.nil? || text.empty? || level <= NONE

          original_length = text.length
          segments = split_segments(text)
          result = segments.map { |seg| seg[:protected] ? seg[:text] : compress_prose(seg[:text], level) }.join

          result = collapse_whitespace(result) if level >= AGGRESSIVE
          log.debug("Compressor applied level=#{level} original=#{original_length} compressed=#{result.length}")
          result
        end

        def summarize_messages(messages, max_tokens: 2000)
          return { summary: '', original_count: 0 } if messages.nil? || messages.empty?

          text = messages.map { |m| "#{m[:role]}: #{m[:content]}" }.join("\n\n")
          return { summary: text, original_count: messages.size, compressed: false } if text.length < max_tokens * 4

          summary = llm_summarize(text, max_tokens)
          if summary
            log.info("[llm][compressor] summarized messages=#{messages.size} summary_chars=#{summary.length}")
            { summary: summary, original_count: messages.size, compressed: true }
          else
            fallback = compress(text, level: AGGRESSIVE)
            log.info(
              "[llm][compressor] fallback_compress messages=#{messages.size} " \
              "input_chars=#{text.length} summary_chars=#{fallback.length}"
            )
            { summary: fallback, original_count: messages.size, compressed: true, method: :stopword }
          end
        end

        # Removes near-duplicate messages from a conversation history.
        # Uses Jaccard similarity on word sets to detect duplicates.
        # Keeps the last occurrence of similar messages.
        #
        # @param messages [Array<Hash>] messages with :role and :content keys
        # @param threshold [Float] similarity threshold (0.0-1.0) above which messages are considered duplicates
        # @return [Hash] { messages: Array, removed: Integer, original_count: Integer }
        def deduplicate_messages(messages, threshold: 0.85)
          return { messages: [], removed: 0, original_count: 0 } if messages.nil? || messages.empty?

          kept = []
          removed = 0

          messages.reverse_each do |msg|
            content = msg[:content].to_s
            next kept.unshift(msg) if content.length < 20

            duplicate = kept.any? do |existing|
              next false unless existing[:role] == msg[:role]

              jaccard_similarity(content, existing[:content].to_s) >= threshold
            end

            if duplicate
              removed += 1
            else
              kept.unshift(msg)
            end
          end

          { messages: kept, removed: removed, original_count: messages.size }
        end

        def auto_compact(messages, target_tokens:, preserve_recent: 10)
          return messages if messages.size <= preserve_recent

          recent = messages.last(preserve_recent)
          older  = messages[0..-(preserve_recent + 1)]

          summarized = summarize_messages(older, max_tokens: target_tokens / 2)

          compaction_msg = {
            role:     'system',
            content:  "[Conversation compacted: #{older.size} turns summarized]",
            metadata: {
              compacted_at:   Time.now.utc.iso8601,
              original_count: messages.size,
              preserved:      recent.size
            }
          }

          summary_msg = {
            role:    'system',
            content: summarized[:summary]
          }

          [compaction_msg, summary_msg, *recent].flatten
        end

        def estimate_tokens(messages)
          return 0 if messages.nil? || messages.empty?

          total_chars = messages.sum { |m| m[:content].to_s.length }
          total_chars / 4
        end

        def stopwords_for_level(level)
          return [] if level <= NONE

          (1..[level, AGGRESSIVE].min).flat_map { |l| LEVEL_WORDS.fetch(l, []) }
        end

        private

        def split_segments(text)
          segments = []

          # Split on fenced code blocks first (```...```)
          parts = text.split(/(```.*?```)/m)
          parts.each do |part|
            if part.start_with?('```')
              segments << { text: part, protected: true }
            else
              # Within non-fenced text, split on inline code (`...`)
              subparts = part.split(/(`[^`\n]+`)/)
              subparts.each do |sub|
                protected = sub.start_with?('`') && sub.end_with?('`') && sub.length > 1
                segments << { text: sub, protected: protected }
              end
            end
          end

          segments
        end

        def compress_prose(text, level)
          words = stopwords_for_level(level)
          return text if words.empty?

          pattern = /\b(#{words.join('|')})\b ?/i
          result = text.gsub(pattern, '')

          # Clean up double spaces left by removals
          result.gsub(/  +/, ' ')
        end

        def collapse_whitespace(text)
          text.gsub(/\n{3,}/, "\n\n")
        end

        def llm_summarize(text, max_tokens)
          return nil unless defined?(Legion::LLM) && Legion::LLM.respond_to?(:chat_direct)

          session = Legion::LLM.chat_direct(model: summarize_model)
          response = session.ask("#{SUMMARIZE_PROMPT}\n\n#{text[0, max_tokens * 8]}")
          response.content
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.compressor.llm_summarize')
          log.debug("[llm][compressor] summarize_failed error=#{e.message}")
          nil
        end

        def summarize_model
          (defined?(Legion::Settings) && Legion::Settings.dig(:llm, :compressor, :model)) || 'gpt-4o-mini'
        end

        def jaccard_similarity(text_a, text_b)
          words_a = text_a.downcase.scan(/\w+/).to_set
          words_b = text_b.downcase.scan(/\w+/).to_set
          return 0.0 if words_a.empty? && words_b.empty?

          intersection = (words_a & words_b).size.to_f
          union = (words_a | words_b).size.to_f
          union.zero? ? 0.0 : intersection / union
        end
      end
    end
  end
end
