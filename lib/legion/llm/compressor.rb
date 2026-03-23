# frozen_string_literal: true

module Legion
  module LLM
    module Compressor
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
          Legion::Logging.debug("Compressor applied level=#{level} original=#{original_length} compressed=#{result.length}") if defined?(Legion::Logging)
          result
        end

        def summarize_messages(messages, max_tokens: 2000)
          return { summary: '', original_count: 0 } if messages.nil? || messages.empty?

          text = messages.map { |m| "#{m[:role]}: #{m[:content]}" }.join("\n\n")
          return { summary: text, original_count: messages.size, compressed: false } if text.length < max_tokens * 4

          summary = llm_summarize(text, max_tokens)
          if summary
            log_debug("summarize_messages: #{messages.size} messages -> #{summary.length} chars")
            { summary: summary, original_count: messages.size, compressed: true }
          else
            fallback = compress(text, level: AGGRESSIVE)
            { summary: fallback, original_count: messages.size, compressed: true, method: :stopword }
          end
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
          log_debug("llm_summarize failed: #{e.message}")
          nil
        end

        def summarize_model
          (defined?(Legion::Settings) && Legion::Settings.dig(:llm, :compressor, :model)) || 'gpt-4o-mini'
        end

        def log_debug(msg)
          Legion::Logging.debug("Compressor: #{msg}") if defined?(Legion::Logging)
        end
      end
    end
  end
end
