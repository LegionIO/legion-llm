# frozen_string_literal: true

require 'securerandom'
require 'uri'
require 'legion/logging/helper'
require_relative '../caller_identity'

module Legion
  module LLM
    module Transport
      class Message < ::Legion::Transport::Message
        include Legion::Logging::Helper

        # Keys stripped from the JSON body (in addition to base ENVELOPE_KEYS).
        # Do NOT add keys already in ENVELOPE_KEYS (:routing_key, :reply_to, etc.).
        # Do NOT add :request_type — metering/audit need it in the body.
        # Do NOT add :message_context — it MUST appear in the body of all 6 messages.
        LLM_ENVELOPE_KEYS = %i[
          fleet_correlation_id ttl
        ].freeze

        def message_context
          @options[:message_context] || {}
        end

        def message
          @options.except(*ENVELOPE_KEYS, *LLM_ENVELOPE_KEYS)
        end

        def message_id
          @message_id ||= @options[:message_id] || "#{message_id_prefix}_#{SecureRandom.uuid}"
        end

        # Fleet messages use :fleet_correlation_id to avoid collision with the
        # base class's :correlation_id (which falls through to :parent_id/:task_id).
        def correlation_id
          @options[:fleet_correlation_id] || super
        end

        def app_id
          @options[:app_id] || 'legion-llm'
        end

        def headers
          super.merge(llm_headers).merge(context_headers).merge(tracing_headers).merge(encryption_headers)
        end

        def encode_message
          payload = message
          payload = Legion::JSON.dump(payload) unless payload.is_a?(String)

          if encrypt? && defined?(Legion::Crypt) && Legion::Crypt.respond_to?(:encrypt)
            encrypted = Legion::Crypt.encrypt(payload)
            @encrypted_iv = encrypted[:iv]
            @options[:content_encoding] = 'encrypted/cs'
            log.debug "[llm][transport] encode_message action=encrypt class=#{self.class.name}"
            return encrypted[:enciphered_message]
          end

          @options[:content_encoding] = 'identity'
          payload
        end

        def content_encoding
          @options[:content_encoding] || super
        end

        def publish_envelope_options(options)
          {
            routing_key:      options[:routing_key] || routing_key || '',
            content_type:     options[:content_type] || content_type,
            content_encoding: options[:content_encoding] || content_encoding,
            type:             options[:type] || type,
            priority:         options[:priority] || priority,
            expiration:       options[:expiration] || expiration,
            headers:          headers,
            persistent:       options.key?(:persistent) ? options[:persistent] : persistent,
            message_id:       message_id,
            correlation_id:   correlation_id,
            reply_to:         reply_to,
            app_id:           app_id,
            timestamp:        timestamp
          }.tap do |envelope|
            envelope[:mandatory] = true if options[:mandatory] == true
          end
        end

        def install_return_listener(exchange_dest, options, return_state)
          return unless options[:mandatory] == true

          return_channel = publish_channel(exchange_dest)
          return unless return_channel.respond_to?(:on_return)

          expected_correlation_id = correlation_id
          expected_message_id = message_id
          return_channel.on_return do |return_info, properties, _content|
            next if properties.respond_to?(:correlation_id) && properties.correlation_id &&
                    expected_correlation_id && properties.correlation_id != expected_correlation_id
            next if properties.respond_to?(:message_id) && properties.message_id &&
                    expected_message_id && properties.message_id != expected_message_id

            return_state[:returned] = true
            return_state[:reply_code] = return_info.reply_code if return_info.respond_to?(:reply_code)
            return_state[:reply_text] = return_info.reply_text if return_info.respond_to?(:reply_text)
          end
        end

        def prepare_publisher_confirms(exchange_dest, options)
          return unless options[:publisher_confirm] == true

          confirm_channel = publish_channel(exchange_dest)
          confirm_channel.confirm_select if confirm_channel.respond_to?(:confirm_select)
        end

        def publish_result(exchange_dest, options, return_state)
          status = confirm_publish(exchange_dest, options)
          status = :unroutable if return_state[:returned]
          ex_name = exchange_dest.respond_to?(:name) ? exchange_dest.name : exchange_dest.to_s
          {
            status:            status,
            accepted:          status == :accepted,
            exchange:          ex_name,
            routing_key:       options[:routing_key] || routing_key || '',
            message_id:        message_id,
            return_reply_code: return_state[:reply_code],
            return_reply_text: return_state[:reply_text],
            correlation_id:    correlation_id
          }.compact
        end

        def publish_failure_result(status, error, options = @options)
          {
            status:         status,
            accepted:       false,
            error_class:    error.class.name,
            error:          error.message,
            routing_key:    options[:routing_key] || routing_key || '',
            message_id:     message_id,
            correlation_id: correlation_id
          }
        end

        def tracing_headers
          tracing = @options[:tracing] || context_value(message_context, :tracing)
          return {} unless tracing.is_a?(Hash)

          trace_id = context_value(tracing, :trace_id)
          span_id = context_value(tracing, :span_id)
          parent_span_id = context_value(tracing, :parent_span_id)
          correlation_id = context_value(tracing, :correlation_id)
          baggage = baggage_header(context_value(tracing, :baggage))

          h = {}
          h['traceparent'] = "00-#{trace_id}-#{span_id}-01" if w3c_trace_id?(trace_id) && w3c_span_id?(span_id)
          h['baggage'] = baggage if baggage
          h['x-legion-trace-id']       = trace_id.to_s       if trace_id
          h['x-legion-span-id']        = span_id.to_s        if span_id
          h['x-legion-parent-span-id'] = parent_span_id.to_s if parent_span_id
          h['x-legion-correlation-id'] = correlation_id.to_s if correlation_id
          h
        end

        private

        def publish_channel(exchange_dest)
          return exchange_dest.channel if exchange_dest.respond_to?(:channel)

          channel
        end

        def confirm_publish(exchange_dest, options)
          return :accepted unless options[:publisher_confirm] == true

          confirm_channel = publish_channel(exchange_dest)
          return :accepted unless confirm_channel.respond_to?(:wait_for_confirms)

          timeout = options[:publish_confirm_timeout_ms]
          confirmed = timeout ? confirm_channel.wait_for_confirms(timeout.to_f / 1000.0) : confirm_channel.wait_for_confirms
          confirmed == false ? :nacked : :accepted
        rescue Timeout::Error => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.transport.confirm_publish')
          :confirm_timeout
        end

        def encryption_headers
          h = {}
          h['iv'] = @encrypted_iv if @encrypted_iv
          h
        end

        def message_id_prefix = 'msg'

        def option_value(*keys)
          keys.each do |key|
            value = @options[key]
            return value if value
          end
          nil
        end

        def llm_headers
          h = {}
          h['x-legion-llm-provider'] = @options[:provider].to_s if @options[:provider]
          model_val = option_value(:model, :model_id)
          h['x-legion-llm-model']          = model_val.to_s                     if model_val
          h['x-legion-llm-request-type']   = @options[:request_type].to_s       if @options[:request_type]
          h['x-legion-llm-schema-version'] = '1.0.0'
          h.merge(identity_headers)
        end

        def identity_headers
          identity = Legion::LLM::CallerIdentity.normalize(caller: @options[:caller], identity: @options[:identity])
          return {} unless identity

          h = {}
          h['x-legion-identity'] = identity[:identity].to_s if identity[:identity]
          cred = identity[:credential]
          h['x-legion-credential'] = cred.to_s if cred
          h['x-legion-hostname']   = identity[:hostname].to_s if identity[:hostname]
          type = identity[:type]
          h['x-legion-caller-type'] = type.to_s if type
          h
        end

        def context_headers
          ctx = message_context
          h = {}
          conversation_id = context_value(ctx, :conversation_id)
          message_id = context_value(ctx, :message_id)
          request_id = context_value(ctx, :request_id)
          h['x-legion-llm-conversation-id'] = conversation_id.to_s if conversation_id
          h['x-legion-llm-message-id']      = message_id.to_s      if message_id
          h['x-legion-llm-request-id']      = request_id.to_s      if request_id
          h
        end

        def context_value(context, key)
          return nil unless context.respond_to?(:key?)
          return context[key] if context.key?(key)

          string_key = key.to_s
          context[string_key] if context.key?(string_key)
        end

        def w3c_trace_id?(value)
          value.to_s.match?(/\A[0-9a-f]{32}\z/) && value.to_s != ('0' * 32)
        end

        def w3c_span_id?(value)
          value.to_s.match?(/\A[0-9a-f]{16}\z/) && value.to_s != ('0' * 16)
        end

        def baggage_header(baggage)
          return nil unless baggage.is_a?(Hash) && !baggage.empty?

          header = baggage.filter_map do |key, value|
            next if value.nil?

            "#{URI.encode_www_form_component(key.to_s)}=#{URI.encode_www_form_component(value.to_s)}"
          end.join(',')
          header.empty? ? nil : header
        end
      end
    end
  end
end
