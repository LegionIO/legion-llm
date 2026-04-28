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
        event_class = metering_event_class if transport_connected?

        if event_class
          event_class.new(**event).publish
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

      def spool_available?
        !!defined?(Legion::Data::Spool)
      end

      def spool_event(event)
        spool = Legion::Data::Spool.for(Legion::LLM)
        spool.write(:metering, event)
      end

      def extract_usage(response)
        return { input_tokens: 0, output_tokens: 0 } unless response.is_a?(Hash)

        usage = settings_value(response, :usage) || {}
        {
          input_tokens:  settings_value(usage, :input_tokens) || settings_value(usage, :prompt_tokens) || 0,
          output_tokens: settings_value(usage, :output_tokens) || settings_value(usage, :completion_tokens) || 0
        }
      end

      def extract_provider(response)
        return nil unless response.is_a?(Hash)

        settings_value(settings_value(response, :meta), :provider) || settings_value(response, :provider)
      end

      def extract_model(response)
        return nil unless response.is_a?(Hash)

        settings_value(settings_value(response, :meta), :model) || settings_value(response, :model)
      end

      def settings_value(hash, key)
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
