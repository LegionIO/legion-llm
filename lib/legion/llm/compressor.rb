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
      end
    end
  end
end
