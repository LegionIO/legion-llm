# frozen_string_literal: true

module Legion
  module LLM
    module Pipeline
      class Timeline
        def initialize
          @events = []
          @seq = 0
          @participant_set = []
        end

        def record(category:, key:, detail:, exchange_id: nil, direction: nil,
                   from: nil, to: nil, duration_ms: nil, data: nil)
          @seq += 1
          @events << {
            seq:         @seq,
            exchange_id: exchange_id,
            timestamp:   Time.now,
            category:    category,
            key:         key,
            direction:   direction,
            from:        from,
            to:          to,
            detail:      detail,
            duration_ms: duration_ms,
            data:        data
          }
          track_participant(from)
          track_participant(to)
        end

        def events
          @events.dup.freeze
        end

        def participants
          @participant_set.dup.freeze
        end

        private

        def track_participant(name)
          return if name.nil?

          @participant_set << name unless @participant_set.include?(name)
        end
      end
    end
  end
end
