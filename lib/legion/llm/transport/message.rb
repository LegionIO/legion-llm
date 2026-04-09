# frozen_string_literal: true

require 'securerandom'

module Legion
  module LLM
    module Transport
      class Message < ::Legion::Transport::Message
        # Keys stripped from the JSON body (in addition to base ENVELOPE_KEYS).
        # Do NOT add keys already in ENVELOPE_KEYS (:routing_key, :reply_to, etc.).
        # Do NOT add :request_type — metering/audit need it in the body.
        # Do NOT add :message_context — it MUST appear in the body of all 6 messages.
        LLM_ENVELOPE_KEYS = %i[
          fleet_correlation_id provider model ttl
        ].freeze

        def message_context
          @options[:message_context] || {}
        end

        def message
          @options.except(*ENVELOPE_KEYS, *LLM_ENVELOPE_KEYS)
        end

        def message_id
          @options[:message_id] || "#{message_id_prefix}_#{SecureRandom.uuid}"
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
          super.merge(llm_headers).merge(context_headers)
        end

        # Subclasses override to inject OpenTelemetry span context.
        # Stub returns empty hash until tracing integration is implemented.
        def tracing_headers
          {}
        end

        private

        def message_id_prefix = 'msg'

        def llm_headers
          h = {}
          h['x-legion-llm-provider']       = @options[:provider].to_s     if @options[:provider]
          h['x-legion-llm-model']          = @options[:model].to_s        if @options[:model]
          h['x-legion-llm-request-type']   = @options[:request_type].to_s if @options[:request_type]
          h['x-legion-llm-schema-version'] = '1.0.0'
          h
        end

        def context_headers
          ctx = message_context
          h = {}
          h['x-legion-llm-conversation-id'] = ctx[:conversation_id].to_s if ctx[:conversation_id]
          h['x-legion-llm-message-id']      = ctx[:message_id].to_s      if ctx[:message_id]
          h['x-legion-llm-request-id']      = ctx[:request_id].to_s      if ctx[:request_id]
          h
        end
      end
    end
  end
end
