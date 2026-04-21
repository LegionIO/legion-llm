# frozen_string_literal: true

module Legion
  module LLM
    module Types
      Chunk = ::Data.define(
        :request_id, :conversation_id, :exchange_id,
        :index, :type, :content_block_index,
        :delta, :tool_call, :usage, :stop_reason,
        :tracing, :timestamp
      ) do
        def self.content_delta(delta:, request_id:, conversation_id: nil, exchange_id: nil, index: 0)
          new(type: :content_delta, delta: delta, index: index,
              request_id: request_id, conversation_id: conversation_id,
              exchange_id: exchange_id, content_block_index: nil,
              tool_call: nil, usage: nil, stop_reason: nil,
              tracing: nil, timestamp: Time.now)
        end

        def self.done(request_id:, usage: nil, stop_reason: nil, conversation_id: nil, exchange_id: nil)
          new(type: :done, request_id: request_id,
              conversation_id: conversation_id, exchange_id: exchange_id,
              usage: usage, stop_reason: stop_reason,
              index: nil, content_block_index: nil,
              delta: nil, tool_call: nil, tracing: nil, timestamp: Time.now)
        end

        def content?
          type == :content_delta
        end

        def done?
          type == :done
        end

        def to_h
          super.compact
        end
      end

      Chunk::CHUNK_TYPES = %i[content_delta thinking_delta tool_call_delta
                              usage done error].freeze
    end
  end
end
