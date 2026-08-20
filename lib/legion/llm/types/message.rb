# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'

module Legion
  module LLM
    module Types
      Message = ::Data.define(
        :id, :parent_id, :role, :content, :tool_calls, :tool_call_id,
        :name, :status, :version, :timestamp, :seq,
        :provider, :model, :input_tokens, :output_tokens,
        :conversation_id, :task_id
      ) do
        extend Legion::Logging::Helper

        def self.build(**kwargs)
          new(
            id:              kwargs[:id] || "msg_#{SecureRandom.hex(12)}",
            parent_id:       kwargs[:parent_id],
            role:            kwargs[:role]&.to_sym || :user,
            content:         kwargs[:content],
            tool_calls:      kwargs[:tool_calls],
            tool_call_id:    kwargs[:tool_call_id],
            name:            kwargs[:name],
            status:          kwargs.fetch(:status, :created),
            version:         kwargs.fetch(:version, 1),
            timestamp:       kwargs[:timestamp] || Time.now,
            seq:             kwargs[:seq],
            provider:        kwargs[:provider],
            model:           kwargs[:model],
            input_tokens:    kwargs[:input_tokens],
            output_tokens:   kwargs[:output_tokens],
            conversation_id: kwargs[:conversation_id],
            task_id:         kwargs[:task_id]
          )
        end

        def self.from_hash(hash)
          hash = hash.transform_keys(&:to_sym) if hash.respond_to?(:transform_keys)
          build(**hash)
        end

        def self.wrap(input)
          return input if input.is_a?(Message)

          from_hash(input) if input.is_a?(Hash)
        end

        def text
          case content
          when String then content
          when Array
            dropped = 0
            text_parts = content.filter_map do |block|
              extracted = text_from_block(block)
              dropped += 1 if extracted.nil?
              extracted
            end
            self.class.log.debug("[types][message] action=text dropped_non_text=#{dropped} id=#{id}") if dropped.positive?
            text_parts.join
          else
            content.to_s
          end
        end

        def full_content
          case content
          when String
            content
          when Array, Hash
            Legion::JSON.dump(content)
          else
            content.to_s
          end
        rescue StandardError => e
          self.class.handle_exception(e, level: :warn, handled: true, operation: 'llm.types.message.full_content')
          content.inspect
        end

        def to_h
          super.compact
        end

        private

        def text_from_block(block)
          return block.text if block.respond_to?(:text)
          return nil unless block.is_a?(Hash)

          type = block[:type] || block['type']
          return nil unless type.nil? || %w[text output_text input_text].include?(type.to_s)

          block[:text] || block['text'] || block[:content] || block['content']
        end
      end
    end
  end
end
