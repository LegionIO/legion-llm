# frozen_string_literal: true

require 'concurrent'

require 'legion/logging/helper'
module Legion
  module LLM
    module Fleet
      module ReplyDispatcher
        extend Legion::Logging::Helper

        @pending = Concurrent::Map.new
        @mutex = Mutex.new
        @consumer = nil

        module_function

        def register(correlation_id, expected: {})
          future = Concurrent::Promises.resolvable_future
          @pending[correlation_id] = { future: future, expected: expected || {} }
          ensure_consumer
          future
        end

        def deregister(correlation_id)
          @pending.delete(correlation_id)
        end

        def handle_delivery(raw_payload, properties = {})
          payload = parse_payload(raw_payload)
          cid = delivery_value(:correlation_id, payload, properties)
          return unless cid

          entry = @pending[cid]
          return unless entry
          return unless expected_delivery?(entry[:expected], payload, properties)

          future = @pending.delete(cid)[:future]

          # Type-aware dispatch (new protocol) with fallback to legacy (no type)
          case delivery_value(:type, payload, properties)
          when 'llm.fleet.error'
            future.fulfill(normalize_error(payload, correlation_id: cid))
          else
            # 'llm.fleet.response' or legacy (no type)
            future.fulfill(payload)
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.reply_dispatcher.handle_delivery')
        end

        def agent_queue_name
          @agent_queue_name ||= "llm.fleet.reply.#{SecureRandom.hex(8)}"
        end

        def pending_count
          @pending.size
        end

        def reset!
          @mutex.synchronize do
            cancel_consumer
            @pending = Concurrent::Map.new
          end
        end

        def ensure_consumer
          @mutex.synchronize do
            return if @consumer
            return unless transport_available?

            channel = Legion::Transport.connection.create_channel
            queue = channel.queue(agent_queue_name, auto_delete: true, durable: false)
            @consumer = queue.subscribe(manual_ack: false) do |_delivery, properties, body|
              props = {
                correlation_id: properties.correlation_id,
                type:           properties.type
              }
              handle_delivery(body, props)
            end
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.reply_dispatcher.ensure_consumer')
        end

        def cancel_consumer
          @consumer&.cancel
          @consumer = nil
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.reply_dispatcher.cancel_consumer')
        end

        def transport_available?
          defined?(Legion::Transport) &&
            Legion::Transport.respond_to?(:connection) &&
            Legion::Transport.connection
        end

        def parse_payload(raw)
          return raw if raw.is_a?(Hash)

          Legion::JSON.load(raw)
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.reply_dispatcher.parse_payload')
          {}
        end

        def normalize_error(payload, correlation_id: nil)
          error = payload_value(payload, :error) || {}
          {
            success:         false,
            error:           normalized_error_code(error),
            correlation_id:  payload_value(payload, :correlation_id) || correlation_id,
            message_context: payload_value(payload, :message_context) || {},
            raw_error:       error
          }
        end

        def normalized_error_code(error)
          return error.to_s unless error.is_a?(Hash)

          payload_value(error, :code) || payload_value(error, :message) || 'fleet_error'
        end

        def expected_delivery?(expected, payload, properties)
          return true unless expected.is_a?(Hash)

          expected.all? do |key, expected_value|
            next true if expected_value.nil?

            actual = delivery_value(key, payload, properties)
            actual && actual.to_s == expected_value.to_s
          end
        end

        def delivery_value(key, payload, properties)
          return properties[key] if properties.is_a?(Hash) && properties.key?(key)
          return properties[key.to_s] if properties.is_a?(Hash) && properties.key?(key.to_s)

          payload_value(payload, key)
        end

        def payload_value(payload, key)
          return payload[key] if payload.is_a?(Hash) && payload.key?(key)
          return payload[key.to_s] if payload.is_a?(Hash) && payload.key?(key.to_s)

          nil
        end
      end
    end
  end
end
