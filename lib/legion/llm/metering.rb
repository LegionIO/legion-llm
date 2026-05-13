# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'metering/estimator'
require_relative 'metering/tracker'
require_relative 'metering/tokens'
require_relative 'metering/usage'
require_relative 'publisher_identity'

module Legion
  module LLM
    module Metering
      extend Legion::Logging::Helper

      def self.load_transport
        return unless defined?(Legion::Transport::Message)

        require_relative 'transport/exchanges/metering'
        require_relative 'transport/messages/metering_event'
      end

      module_function

      def emit(event)
        event = attributed_event(event)
        event_class = metering_event_class if transport_connected?

        if event_class
          event_class.new(**event).publish
          log.info("[llm][metering] published provider=#{event[:provider]} model=#{event[:model_id]}")
          :published
        else
          log.warn("[llm][metering] dropped provider=#{event[:provider]} model=#{event[:model_id]} reason=transport_unavailable")
          :dropped
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.metering.emit')
        :dropped
      end

      def attributed_event(event)
        source = event.is_a?(Hash) ? event.dup : {}
        source[:identity] = Legion::LLM::PublisherIdentity.current
        source[:caller] ||= Legion::LLM::PublisherIdentity.caller_hash
        source
      end

      def flush_spool
        log.debug('[llm][metering] spool disabled; metering events are transport-only')
        0
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.metering.flush_spool')
        0
      end

      def install_hook
        Legion::LLM::Hooks.after_chat do |response:, model:, caller: nil, **|
          usage = extract_usage(response)
          next if usage[:input_tokens].zero? && usage[:output_tokens].zero?

          resolved_model    = (extract_model(response) || model).to_s
          resolved_provider = extract_provider(response)

          Metering::Recorder.record(
            model:         resolved_model,
            input_tokens:  usage[:input_tokens],
            output_tokens: usage[:output_tokens],
            provider:      resolved_provider
          )

          emit(
            provider:      resolved_provider,
            model_id:      resolved_model,
            input_tokens:  usage[:input_tokens],
            output_tokens: usage[:output_tokens],
            caller:        caller,
            event_type:    'llm_completion',
            status:        response.is_a?(Hash) && response[:error] ? 'failure' : 'success'
          )
          nil
        end
      end

      def transport_connected?
        Legion::LLM::Settings.transport_connected?
      end

      def metering_event_class
        return Legion::LLM::Transport::Messages::MeteringEvent if defined?(Legion::LLM::Transport::Messages::MeteringEvent)

        load_transport
        return Legion::LLM::Transport::Messages::MeteringEvent if defined?(Legion::LLM::Transport::Messages::MeteringEvent)

        Legion::LLM::Metering::Event
      rescue NameError, LoadError => e
        handle_exception(e, level: :warn, handled: true, operation: 'llm.metering.event_class')
        nil
      end

      def extract_usage(response)
        return { input_tokens: 0, output_tokens: 0 } unless response.is_a?(Hash)

        usage = extract_hash_value(response, :usage) || {}
        {
          input_tokens:  extract_hash_value(usage, :input_tokens) || extract_hash_value(usage, :prompt_tokens) || 0,
          output_tokens: extract_hash_value(usage, :output_tokens) || extract_hash_value(usage, :completion_tokens) || 0
        }
      end

      def extract_provider(response)
        return nil unless response.is_a?(Hash)

        extract_hash_value(extract_hash_value(response, :meta), :provider) || extract_hash_value(response, :provider)
      end

      def extract_model(response)
        return nil unless response.is_a?(Hash)

        extract_hash_value(extract_hash_value(response, :meta), :model) || extract_hash_value(response, :model)
      end

      def extract_hash_value(hash, key)
        return nil unless hash.respond_to?(:key?)

        string_key = key.to_s
        return hash[string_key] if hash.key?(string_key)

        hash[key] if hash.key?(key)
      end

      # Backward-compat: resolve old Legion::LLM::Metering::Exchange, ::Event
      def self.const_missing(name)
        case name
        when :Exchange
          require_relative 'transport/exchanges/metering'
          Transport::Exchanges::Metering
        when :Event
          require_relative 'transport/messages/metering_event'
          Transport::Messages::MeteringEvent
        else
          super
        end
      end
    end
  end
end
