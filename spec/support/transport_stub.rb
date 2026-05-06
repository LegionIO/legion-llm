# frozen_string_literal: true

# Stub Legion::Transport base classes for standalone testing of LLM transport messages.
# Prefer the real transport contract when available so local stubs do not collide
# with gems that load legion-transport later in the same process.
begin
  ENV['LEGION_MODE'] ||= 'lite'
  require 'legion/transport'

  module Legion
    module LLM
      module SpecTransport
        class DefaultExchange
          attr_reader :channel, :name, :published_payload, :published_options

          def initialize(channel)
            @channel = channel
            @name = ''
          end

          def publish(payload, **options)
            @published_payload = payload
            @published_options = options
            true
          end
        end

        class Channel
          attr_reader :confirm_timeout, :default_exchange

          def initialize
            @open = true
            @default_exchange = DefaultExchange.new(self)
          end

          def open? = @open
          def prefetch(*) = true

          def confirm_select = true

          def wait_for_confirms(timeout = nil)
            @confirm_timeout = timeout
            true
          end

          def on_return(&); end
        end
      end
    end
  end

  class << Legion::Transport::Connection
    def channel
      @channel ||= Legion::LLM::SpecTransport::Channel.new
    end
  end
rescue LoadError
  # Older standalone test environments may not install legion-transport.
end

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

        def publish_envelope_options(options)
          {
            routing_key:      options[:routing_key] || routing_key || '',
            content_type:     options[:content_type] || content_type,
            content_encoding: options[:content_encoding] || content_encoding,
            headers:          headers,
            type:             options[:type] || type,
            priority:         options[:priority] || priority,
            expiration:       options[:expiration] || expiration,
            message_id:       message_id,
            correlation_id:   correlation_id,
            reply_to:         @options[:reply_to],
            app_id:           app_id,
            timestamp:        timestamp
          }.tap do |envelope|
            envelope[:mandatory] = true if options[:mandatory] == true
          end
        end

        def install_return_listener(exchange_dest, options, return_state)
          return unless options[:mandatory] == true
          return unless exchange_dest.channel.respond_to?(:on_return)

          exchange_dest.channel.on_return { return_state[:returned] = true }
        end

        def prepare_publisher_confirms(exchange_dest, options)
          return unless options[:publisher_confirm] == true

          exchange_dest.channel.confirm_select if exchange_dest.channel.respond_to?(:confirm_select)
        end

        def publish_result(exchange_dest, options, return_state)
          status = return_state[:returned] ? :unroutable : :accepted
          if options[:publisher_confirm] == true && exchange_dest.channel.respond_to?(:wait_for_confirms)
            confirmed = exchange_dest.channel.wait_for_confirms(options[:publish_confirm_timeout_ms].to_f / 1000.0)
            status = :nacked if confirmed == false
          end

          {
            status:         status,
            accepted:       status == :accepted,
            exchange:       exchange_dest.name,
            routing_key:    options[:routing_key] || routing_key || '',
            message_id:     message_id,
            correlation_id: correlation_id
          }
        end

        def publish_failure_result(status, error)
          {
            status:         status,
            accepted:       false,
            error_class:    error.class.name,
            error:          error.message,
            routing_key:    routing_key || '',
            message_id:     message_id,
            correlation_id: correlation_id
          }
        end
      end
    end
  end
end
