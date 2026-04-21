# frozen_string_literal: true

module Legion
  module LLM
    module Router
      class EscalationChain
        include Enumerable

        attr_reader :max_attempts

        def initialize(resolutions:, max_attempts: 3)
          @resolutions = resolutions.dup.freeze
          @max_attempts = max_attempts
        end

        def primary
          @resolutions.first
        end

        def each(&)
          return enum_for(:each) unless block_given?

          padded_resolutions.each(&)
        end

        def size
          @resolutions.size
        end

        def empty?
          @resolutions.empty?
        end

        def to_a
          @resolutions.dup
        end

        private

        def padded_resolutions
          return @resolutions.first(@max_attempts) if @resolutions.size >= @max_attempts

          last = @resolutions.last
          (@resolutions + Array.new(@max_attempts - @resolutions.size) { last }).first(@max_attempts)
        end
      end
    end
  end
end
