# frozen_string_literal: true

require 'concurrent'
require 'securerandom'

require 'legion/extensions/llm/fleet/protocol'
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
          @pending[correlation_id] = { future: future, expected: normalize_hash(expected || {}) }
          ensure_consumer
          future
        rescue StandardError
          @pending.delete(correlation_id)
          raise
        end

        def deregister(correlation_id)
          @pending.delete(correlation_id)
        end

        def handle_delivery(raw_payload, properties = {})
          payload = normalize_hash(parse_payload(raw_payload))
          properties = normalize_hash(properties)
          return unless accepted_type?(delivery_value(:type, payload, properties))
          return unless accepted_protocol?(payload)
          return unless payload[:operation]

          cid = correlation_id_for(payload, properties)
          return unless cid

          entry = @pending[cid]
          return unless entry
          return unless expected_delivery?(entry[:expected], payload, properties)

          future = @pending.delete(cid)&.[](:future)
          return unless future

          if delivery_value(:type, payload, properties) == ::Legion::Extensions::Llm::Fleet::Protocol::ERROR_TYPE
            future.fulfill(normalize_error(payload, correlation_id: cid))
          else
            future.fulfill(payload)
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.fleet.reply_dispatcher.handle_delivery')
        end

        def agent_queue_name
          @mutex.synchronize { current_agent_queue_name }
        end

        def pending_count
          @pending.size
        end

        def reset!
          @mutex.synchronize do
            cancel_consumer
            @pending = Concurrent::Map.new
            @current_agent_queue_name = nil
          end
        end

        def ensure_consumer
          @mutex.synchronize do
            return if @consumer
            return unless transport_available?

            channel = Legion::Transport.connection.create_channel
            queue = channel.queue(current_agent_queue_name, auto_delete: true, durable: false,
                                                    expires: reply_queue_expires_ms)
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
          raise
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

        def accepted_type?(type)
          [
            ::Legion::Extensions::Llm::Fleet::Protocol::RESPONSE_TYPE,
            ::Legion::Extensions::Llm::Fleet::Protocol::ERROR_TYPE
          ].include?(type.to_s)
        end

        def accepted_protocol?(payload)
          payload[:protocol_version] == ::Legion::Extensions::Llm::Fleet::Protocol::VERSION ||
            payload[:protocol_version] == ::Legion::Extensions::Llm::Fleet::Protocol::VERSION.to_s
        end

        def normalize_error(payload, correlation_id: nil)
          code = payload[:code] || payload.dig(:error, :code) || payload[:message] || 'fleet_error'
          {
            success:         false,
            error:           code,
            correlation_id:  payload[:correlation_id] || correlation_id,
            message_context: payload[:message_context] || {}
          }
        end

        def expected_delivery?(expected, payload, properties)
          expected.all? do |key, expected_value|
            next true if expected_value.nil?

            actual = key.to_sym == :correlation_id ? payload[:correlation_id] : delivery_value(key, payload, properties)
            actual && actual.to_s == expected_value.to_s
          end
        end

        def correlation_id_for(payload, properties)
          payload_cid = payload[:correlation_id]
          return nil if payload_cid.to_s.empty?

          property_cid = properties[:correlation_id]
          return nil if property_cid && property_cid.to_s != payload_cid.to_s

          payload_cid
        end

        def delivery_value(key, payload, properties)
          return properties[key] if key.to_sym == :type && properties.is_a?(Hash) && properties.key?(key)

          payload[key] if payload.is_a?(Hash)
        end

        def normalize_hash(hash)
          return {} unless hash.respond_to?(:each)

          hash.each_with_object({}) do |(key, value), result|
            result[key.respond_to?(:to_sym) ? key.to_sym : key] = normalize_value(value)
          end
        end

        def normalize_value(value)
          case value
          when Hash
            normalize_hash(value)
          when Array
            value.map { |entry| normalize_value(entry) }
          else
            value
          end
        end

        def reply_queue_prefix
          Legion::LLM::Settings.value(:fleet, :dispatch, :reply_queue_prefix, default: 'llm.fleet.reply')
        end

        def reply_queue_expires_ms
          Legion::LLM::Settings.value(:fleet, :dispatch, :reply_queue_expires_ms, default: 60_000)
        end

        def current_agent_queue_name
          @current_agent_queue_name ||= "#{reply_queue_prefix}.#{SecureRandom.hex(8)}"
        end
      end
    end
  end
end
