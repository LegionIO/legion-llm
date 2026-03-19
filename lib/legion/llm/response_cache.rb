# frozen_string_literal: true

require 'fileutils'
require 'json'

module Legion
  module LLM
    module ResponseCache
      DEFAULT_TTL      = 300
      SPOOL_THRESHOLD  = 8 * 1024 * 1024 # 8 MB
      SPOOL_DIR        = File.expand_path('~/.legionio/data/spool/llm_responses').freeze

      module_function

      # Sets status to :pending for a new request.
      def init_request(request_id, ttl: DEFAULT_TTL)
        cache_set(status_key(request_id), 'pending', ttl)
      end

      # Writes response, meta, and marks status as :done.
      def complete(request_id, response:, meta:, ttl: DEFAULT_TTL)
        write_response(request_id, response, ttl)
        cache_set(meta_key(request_id), ::JSON.dump(meta), ttl)
        cache_set(status_key(request_id), 'done', ttl)
      end

      # Writes error details and marks status as :error.
      def fail_request(request_id, code:, message:, ttl: DEFAULT_TTL)
        payload = ::JSON.dump({ code: code, message: message })
        cache_set(error_key(request_id), payload, ttl)
        cache_set(status_key(request_id), 'error', ttl)
      end

      # Returns :pending, :done, :error, or nil.
      def status(request_id)
        raw = Legion::Cache.get(status_key(request_id))
        raw&.to_sym
      end

      # Returns the response string (handles spool overflow transparently).
      def response(request_id)
        raw = Legion::Cache.get(response_key(request_id))
        return nil if raw.nil?
        return File.read(raw.delete_prefix('spool:')) if raw.start_with?('spool:')

        raw
      end

      # Returns meta hash with symbolized keys, or nil.
      def meta(request_id)
        raw = Legion::Cache.get(meta_key(request_id))
        return nil if raw.nil?

        ::JSON.parse(raw, symbolize_names: true)
      end

      # Returns { code:, message: } hash, or nil.
      def error(request_id)
        raw = Legion::Cache.get(error_key(request_id))
        return nil if raw.nil?

        ::JSON.parse(raw, symbolize_names: true)
      end

      # Blocking poll. Returns { status: :done, response:, meta: },
      # { status: :error, error: }, or { status: :timeout }.
      def poll(request_id, timeout: DEFAULT_TTL, interval: 0.1)
        deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout

        loop do
          current = status(request_id)

          case current
          when :done
            return { status: :done, response: response(request_id), meta: meta(request_id) }
          when :error
            return { status: :error, error: error(request_id) }
          end

          return { status: :timeout } if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline

          sleep interval
        end
      end

      # Removes all cache keys for a request (and any spool file).
      def cleanup(request_id)
        raw = Legion::Cache.get(response_key(request_id))
        if raw&.start_with?('spool:')
          path = raw.delete_prefix('spool:')
          FileUtils.rm_f(path)
        end

        Legion::Cache.delete(status_key(request_id))
        Legion::Cache.delete(response_key(request_id))
        Legion::Cache.delete(meta_key(request_id))
        Legion::Cache.delete(error_key(request_id))
      end

      # ── private helpers ────────────────────────────────────────────────
      private_class_method def self.status_key(request_id)
        "llm:#{request_id}:status"
      end

      private_class_method def self.response_key(request_id)
        "llm:#{request_id}:response"
      end

      private_class_method def self.meta_key(request_id)
        "llm:#{request_id}:meta"
      end

      private_class_method def self.error_key(request_id)
        "llm:#{request_id}:error"
      end

      private_class_method def self.cache_set(key, value, ttl)
        Legion::Cache.set(key, value, ttl)
      end

      private_class_method def self.write_response(request_id, response_text, ttl)
        if response_text.bytesize > SPOOL_THRESHOLD
          FileUtils.mkdir_p(SPOOL_DIR)
          path = File.join(SPOOL_DIR, "#{request_id}.txt")
          File.write(path, response_text)
          cache_set(response_key(request_id), "spool:#{path}", ttl)
        else
          cache_set(response_key(request_id), response_text, ttl)
        end
      end
    end
  end
end
