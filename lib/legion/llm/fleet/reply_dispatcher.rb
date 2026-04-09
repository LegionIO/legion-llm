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

        def register(correlation_id)
          future = Concurrent::Promises.resolvable_future
          @pending[correlation_id] = future
          ensure_consumer
          future
        end

        def deregister(correlation_id)
          @pending.delete(correlation_id)
        end

        def handle_delivery(raw_payload, properties = {})
          payload = parse_payload(raw_payload)
          cid = properties[:correlation_id] || payload[:correlation_id]
          return unless cid

          future = @pending.delete(cid)
          return unless future

          # Type-aware dispatch (new protocol) with fallback to legacy (no type)
          case properties[:type]
          when 'llm.fleet.error'
            future.fulfill(normalize_error(payload))
          else
            # 'llm.fleet.response' or legacy (no type)
            future.fulfill(payload)
          end
        rescue StandardError => e
          handle_exception(e, level: :warn)
        end

        def fulfill_return(correlation_id)
          future = @pending.delete(correlation_id)
          return unless future

          future.fulfill({ success: false, error: 'no_fleet_queue' })
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.reply_dispatcher.fulfill_return')
        end

        def fulfill_nack(correlation_id)
          future = @pending.delete(correlation_id)
          return unless future

          future.fulfill({ success: false, error: 'fleet_backpressure' })
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.reply_dispatcher.fulfill_nack')
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
          handle_exception(e, level: :warn)
        end

        def cancel_consumer
          @consumer&.cancel
          @consumer = nil
        rescue StandardError => e
          handle_exception(e, level: :warn)
        end

        def transport_available?
          defined?(Legion::Transport) &&
            Legion::Transport.respond_to?(:connection) &&
            Legion::Transport.connection
        end

        def parse_payload(raw)
          return raw if raw.is_a?(Hash)

          if defined?(Legion::JSON)
            Legion::JSON.load(raw)
          else
            require 'json'
            ::JSON.parse(raw, symbolize_names: true)
          end
        rescue StandardError => e
          handle_exception(e, level: :debug)
          {}
        end

        def normalize_error(payload)
          error = payload[:error] || {}
          {
            success:         false,
            error:           error.is_a?(Hash) ? error[:code] || error[:message] || 'fleet_error' : error.to_s,
            message_context: payload[:message_context] || {},
            raw_error:       error
          }
        end
      end
    end
  end
end
