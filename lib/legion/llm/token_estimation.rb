# frozen_string_literal: true

require 'legion/json'
require 'legion/logging/helper'

module Legion
  module LLM
    module TokenEstimation
      extend Legion::Logging::Helper

      CHARS_PER_TOKEN = 4
      OVERHEAD_PER_MESSAGE = 4

      module_function

      def estimate(messages:, model:, system: nil, tools: nil)
        log.debug("[llm][token_estimation] action=estimate model=#{model} messages=#{messages.size}")

        total_chars = 0
        total_chars += system.to_s.length if system

        messages.each do |msg|
          content = msg[:content] || msg['content']
          total_chars += content_length(content)
          total_chars += OVERHEAD_PER_MESSAGE
        end

        tools.each { |tool| total_chars += Legion::JSON.dump(tool).length } if tools.is_a?(Array) && tools.any?

        { input_tokens: (total_chars.to_f / CHARS_PER_TOKEN).ceil }
      end

      def content_length(content)
        case content
        when String then content.length
        when Array
          content.sum do |block|
            b = block.respond_to?(:transform_keys) ? block.transform_keys(&:to_sym) : block
            (b[:text] || b['text']).to_s.length
          end
        when nil then 0
        else
          content.to_s.length
        end
      end
    end
  end
end
