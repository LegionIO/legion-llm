# frozen_string_literal: true

module Legion
  module LLM
    module Capabilities
      ALIASES = {
        function_calling: :tools,
        functions:        :tools,
        tool:             :tools,
        tool_use:         :tools,
        tool_calls:       :tools,
        stream:           :streaming,
        stream_chat:      :streaming,
        responses_api:    :responses
      }.freeze

      module_function

      def normalize(capabilities)
        Array(capabilities).compact.each_with_object([]) do |capability, normalized|
          next unless capability.respond_to?(:to_s)

          sym = capability.to_s.downcase.strip.tr('-', '_').to_sym
          next if sym.to_s.empty?

          normalized << sym
          normalized << ALIASES[sym] if ALIASES[sym]
        end.uniq
      end

      def merge(*sets)
        sets.flat_map { |set| normalize(set) }.uniq
      end

      def include_all?(available, required)
        required = normalize(required)
        return true if required.empty?

        normalized = normalize(available)
        return false if normalized.empty?

        required.all? { |capability| normalized.include?(capability) }
      end
    end
  end
end
