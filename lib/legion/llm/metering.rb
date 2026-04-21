# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'metering/estimator'
require_relative 'metering/tracker'
require_relative 'metering/tokens'
require_relative 'metering/usage'

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
        if transport_connected? && defined?(Legion::LLM::Transport::Messages::MeteringEvent)
          Legion::LLM::Transport::Messages::MeteringEvent.new(**event).publish
          log.info("[llm][metering] published provider=#{event[:provider]} model=#{event[:model_id]}")
          :published
        elsif spool_available?
          spool_event(event)
          log.info("[llm][metering] spooled provider=#{event[:provider]} model=#{event[:model_id]}")
          :spooled
        else
          log.warn("[llm][metering] dropped provider=#{event[:provider]} model=#{event[:model_id]}")
          :dropped
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.metering.emit')
        :dropped
      end

      def flush_spool
        return 0 unless spool_available? && transport_connected?

        spool = Legion::Data::Spool.for(Legion::LLM)
        flushed = spool.flush(:metering) { |event| emit(event) }
        log.info("[llm][metering] spool_flushed count=#{flushed}")
        flushed
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.metering.flush_spool')
        0
      end

      def install_hook
        Legion::LLM::Hooks.after_chat do |response:, model:, **|
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
            event_type:    'llm_completion',
            status:        response.is_a?(Hash) && response[:error] ? 'failure' : 'success'
          )
          nil
        end
      end

      def transport_connected?
        !!(defined?(Legion::Settings) &&
          Legion::Settings[:transport][:connected] == true)
      end

      def spool_available?
        !!defined?(Legion::Data::Spool)
      end

      def spool_event(event)
        spool = Legion::Data::Spool.for(Legion::LLM)
        spool.write(:metering, event)
      end

      def extract_usage(response)
        return { input_tokens: 0, output_tokens: 0 } unless response.is_a?(Hash)

        usage = response[:usage] || {}
        {
          input_tokens:  usage[:input_tokens] || usage[:prompt_tokens] || 0,
          output_tokens: usage[:output_tokens] || usage[:completion_tokens] || 0
        }
      end

      def extract_provider(response)
        return nil unless response.is_a?(Hash)

        response.dig(:meta, :provider) || response[:provider]
      end

      def extract_model(response)
        return nil unless response.is_a?(Hash)

        response.dig(:meta, :model) || response[:model]
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
