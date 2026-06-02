# frozen_string_literal: true

require 'legion/logging/helper'
require 'fileutils'
require_relative 'metering/estimator'
require_relative 'metering/tracker'
require_relative 'metering/tokens'
require_relative 'metering/usage'
require_relative 'publisher_identity'

module Legion
  module LLM
    module Metering
      extend Legion::Logging::Helper

      SPOOL_DIR = File.expand_path('~/.legionio/data/spool/metering')
      SPOOL_FILE = File.join(SPOOL_DIR, 'events.jsonl').freeze
      SPOOL_MUTEX = Mutex.new

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
          spool_event(event)
          log.info("[llm][metering] spooled provider=#{event[:provider]} model=#{event[:model_id]} reason=transport_unavailable")
          :spooled
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.metering.emit')
        :dropped
      end

      def attributed_event(event)
        source = event.is_a?(Hash) ? event.dup : {}
        source[:identity] ||= Legion::LLM::PublisherIdentity.current
        source[:caller] ||= Legion::LLM::PublisherIdentity.caller_hash
        source
      end

      def flush_spool
        return 0 unless File.exist?(spool_file_path)

        event_class = metering_event_class
        unless event_class && transport_connected?
          log.debug('[llm][metering] flush_spool skipped reason=transport_unavailable')
          return 0
        end

        # Read and truncate atomically under the mutex so no events written
        # between read and truncate can be silently lost.
        events = SPOOL_MUTEX.synchronize do
          path = spool_file_path
          return 0 unless File.exist?(path)

          lines = File.readlines(path, chomp: true)
          parsed = lines.filter_map do |line|
            next if line.strip.empty?

            decrypted = decrypt_spool_line(line)
            Legion::JSON.load(decrypted)
          end
          File.write(path, '')
          parsed
        end

        return 0 if events.empty?

        batch_sleep = spool_settings[:flush_batch_sleep] || 0.0
        flushed = 0

        events.each_with_index do |event_data, index|
          event_class.new(**event_data).publish
          flushed += 1
          sleep(batch_sleep) if batch_sleep.positive? && index < events.size - 1
        end

        log.info("[llm][metering] flush_spool flushed=#{flushed}")
        flushed
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
            provider:              resolved_provider,
            model_id:              resolved_model,
            request_type:          'chat',
            tier:                  extract_tier(response),
            input_tokens:          usage[:input_tokens],
            output_tokens:         usage[:output_tokens],
            thinking_tokens:       usage[:thinking_tokens] || 0,
            total_tokens:          usage[:input_tokens] + usage[:output_tokens],
            finish_reason:         extract_finish_reason(response),
            error_category:        extract_error_category(response),
            error_code:            extract_error_code(response),
            error_message:         extract_error_message(response),
            provider_instance:     extract_provider_instance(response),
            dispatch_path:         extract_dispatch_path(response),
            route_attempts:        extract_route_attempts(response),
            provider_response_ref: response.respond_to?(:provider_response_id) ? response.provider_response_id : nil,
            latency_ms:            extract_latency_ms(response),
            wall_clock_ms:         extract_wall_clock_ms(response),
            caller:                caller,
            event_type:            'llm_completion',
            status:                extract_status(response)
          )
          nil
        end
      end

      def transport_connected?
        Legion::Settings.dig(:transport, :connected) == true
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

      # --- Spool internals (private) ---

      def spool_event(event)
        SPOOL_MUTEX.synchronize do
          ensure_spool_dir
          enforce_max_events
          json = Legion::JSON.dump(event)
          line = if encrypt_spool?
                   Legion::Crypt.encrypt(json)
                 else
                   json
                 end
          File.open(spool_file_path, 'a') { |f| f.puts(line) }
        end
        log.debug("[llm][metering] spool_event written provider=#{event[:provider]} model=#{event[:model_id]}")
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.metering.spool_event')
      end

      def encrypt_spool?
        defined?(Legion::Crypt) &&
          Legion::Crypt.respond_to?(:encrypt) &&
          Legion::Settings.dig(:llm, :compliance, :encrypt_spool) == true
      rescue StandardError
        false
      end

      def decrypt_spool_line(line)
        return line unless defined?(Legion::Crypt) && Legion::Crypt.respond_to?(:decrypt)
        return line if line.start_with?('{')

        Legion::Crypt.decrypt(line)
      rescue StandardError
        line
      end

      def read_spool
        SPOOL_MUTEX.synchronize do
          path = spool_file_path
          return [] unless File.exist?(path)

          lines = File.readlines(path, chomp: true)
          lines.filter_map do |line|
            next if line.strip.empty?

            Legion::JSON.load(line)
          end
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.metering.read_spool')
        []
      end

      def truncate_spool
        SPOOL_MUTEX.synchronize do
          path = spool_file_path
          File.write(path, '') if File.exist?(path)
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'llm.metering.truncate_spool')
      end

      def enforce_max_events
        path = spool_file_path
        return unless File.exist?(path)

        max = spool_settings[:max_events] || 10_000
        lines = File.readlines(path, chomp: true)
        return if lines.size < max

        # Drop oldest events to make room
        trimmed = lines.last(max - 1)
        File.write(path, trimmed.map { |l| "#{l}\n" }.join)
        log.debug("[llm][metering] enforce_max_events trimmed=#{lines.size - trimmed.size} max=#{max}")
      end

      def ensure_spool_dir
        FileUtils.mkdir_p(spool_dir_path)
      end

      def spool_settings
        settings = Legion::Settings.dig(:llm, :metering, :spool) || {}
        settings.is_a?(Hash) ? settings : {}
      end

      # Resolve spool file path at call time, honouring operator-configured
      # paths (e.g. for containerised deployments where $HOME is not writable).
      # Falls back to the compile-time SPOOL_FILE constant.
      def spool_file_path
        configured = spool_settings[:path]
        configured && !configured.to_s.strip.empty? ? configured.to_s : SPOOL_FILE
      end

      def spool_dir_path
        File.dirname(spool_file_path)
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

      # --- Extractor helpers for after_chat hook ---

      def extract_finish_reason(response)
        return nil unless response.is_a?(Hash)

        response[:finish_reason] || response.dig(:stop, :reason) || response.dig(:choices, 0, :finish_reason)
      end

      def extract_tier(response)
        return nil unless response.is_a?(Hash)

        response[:tier] || response.dig(:routing, :tier)
      end

      def extract_error_category(response)
        return nil unless response.is_a?(Hash)

        response[:error_category] || response.dig(:error, :category)
      end

      def extract_error_code(response)
        return nil unless response.is_a?(Hash)

        response[:error_code] || response.dig(:error, :code)
      end

      def extract_error_message(response)
        return nil unless response.is_a?(Hash)

        response[:error_message] || response.dig(:error, :message)
      end

      def extract_provider_instance(response)
        return nil unless response.is_a?(Hash)

        response[:provider_instance] || response.dig(:routing, :provider_instance) || response[:instance]
      end

      def extract_dispatch_path(response)
        return nil unless response.is_a?(Hash)

        response[:dispatch_path] || response[:tier] || response.dig(:routing, :tier)
      end

      def extract_route_attempts(response)
        return nil unless response.is_a?(Hash)

        (response[:route_attempts] || 0).to_i
      end

      def extract_latency_ms(response)
        return nil unless response.is_a?(Hash)

        (response[:latency_ms] || response.dig(:timing, :latency_ms) || 0).to_i
      end

      def extract_wall_clock_ms(response)
        return nil unless response.is_a?(Hash)

        (response[:wall_clock_ms] || response.dig(:timing, :wall_clock_ms) || 0).to_i
      end

      def extract_status(response)
        return 'success' unless response.is_a?(Hash)

        response[:error] ? 'failure' : 'success'
      end
    end
  end
end
