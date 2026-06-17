# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Capabilities
      extend Legion::Logging::Helper

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
        Array(capabilities).compact.filter_map do |capability|
          next unless capability.respond_to?(:to_s)

          sym = capability.to_s.downcase.strip.tr('-', '_').to_sym
          next if sym.to_s.empty?

          ALIASES.fetch(sym, sym)
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
