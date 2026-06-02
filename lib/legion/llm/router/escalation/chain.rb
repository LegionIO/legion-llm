# frozen_string_literal: true

module Legion
  module LLM
    module Router
      class EscalationChain
        include Enumerable
        include Legion::Logging::Helper

        attr_reader :max_attempts

        def initialize(resolutions:, max_attempts: 3)
          @resolutions = resolutions.dup.freeze
          @max_attempts = max_attempts
          log.debug "[llm][escalation_chain] action=built size=#{@resolutions.size} max_attempts=#{@max_attempts} " \
                    "providers=#{@resolutions.map { |r| "#{r.provider}:#{r.model}" }.join(', ')}"
        end

        def primary
          @resolutions.first
        end

        def each(&)
          return enum_for(:each) unless block_given?

          capped_resolutions.each(&)
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

        def capped_resolutions
          return [] if @resolutions.empty?

          @resolutions.first(@max_attempts)
        end
      end
    end
  end
end
