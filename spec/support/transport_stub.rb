# frozen_string_literal: true

# Stub Legion::Transport base classes for standalone testing of LLM transport messages.
# Only defined when the real legion-transport gem is not loaded.
unless defined?(Legion::Transport::Message) && Legion::Transport::Message.instance_method(:initialize).parameters.any?
  module Legion
    module Transport
      class Exchange
        def exchange_name = ''
        def default_type  = 'direct'

        # Class-level DSL for backwards compat with legacy exchange definitions
        def self.exchange_name(name = nil)
          return @exchange_name unless name

          @exchange_name = name
        end

        def self.exchange_type(type = nil)
          return @exchange_type unless type

          @exchange_type = type
        end
      end

      class Message
        # Class-level DSL for backwards compat with legacy message definitions
        def self.routing_key(key = nil)
          return @routing_key unless key

          @routing_key = key
        end

        ENVELOPE_KEYS = %i[
          headers content_type content_encoding persistent expiration
          priority app_id user_id reply_to correlation_id message_id
          routing_key exchange type
        ].freeze

        def initialize(**options)
          @options = options
          @valid = true
          validate
        end

        def validate
          @valid = true
        end

        def message
          @options.except(*ENVELOPE_KEYS)
        end

        def message_id
          @options[:message_id] || @options[:task_id]
        end

        def correlation_id
          @options[:correlation_id] || @options[:parent_id] || @options[:task_id]
        end

        def app_id
          @options[:app_id] || 'legion'
        end

        def headers
          h = {}
          %i[task_id parent_id master_id chain_id].each do |key|
            h[key.to_s] = @options[key].to_s if @options[key]
          end
          h
        end

        def routing_key
          @options[:routing_key]
        end

        def type
          @options[:type]
        end

        def priority
          @options[:priority] || 0
        end

        def expiration
          @options[:expiration]
        end

        def timestamp
          @options[:timestamp] || Time.now.to_i
        end

        def content_type
          'application/json'
        end

        def content_encoding
          'identity'
        end

        def encrypt?
          @options[:encrypt] == true
        end

        def encode_message
          if defined?(Legion::JSON)
            Legion::JSON.dump(message)
          else
            require 'json'
            ::JSON.generate(message)
          end
        end

        def validate_payload_size
          true
        end

        def channel
          @options[:channel]
        end

        def spool_message(error)
          # no-op in test
        end

        def publish(_options = @options)
          raise unless @valid

          validate_payload_size
        end
      end
    end
  end
end
