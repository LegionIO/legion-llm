# frozen_string_literal: true

require 'securerandom'
require 'uri'

module Legion
  module LLM
    module Transport
      class Message < ::Legion::Transport::Message
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
          super.merge(llm_headers).merge(context_headers).merge(tracing_headers)
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
          caller = @options[:caller]
          return {} unless caller.is_a?(Hash)

          rb = caller[:requested_by] || caller['requested_by'] || {}
          h = {}
          identity = rb[:identity] || rb['identity'] || rb[:username] || rb['username']
          h['x-legion-identity']   = identity.to_s   if identity
          h['x-legion-credential'] = (rb[:credential] || rb['credential']).to_s if rb[:credential] || rb['credential']
          h['x-legion-hostname']   = (rb[:hostname] || rb['hostname']).to_s     if rb[:hostname] || rb['hostname']
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
