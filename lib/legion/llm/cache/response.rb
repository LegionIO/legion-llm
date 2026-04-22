# frozen_string_literal: true

require 'fileutils'
require 'json'

require 'legion/logging/helper'
module Legion
  module LLM
    module Cache
      module Response
        extend Legion::Logging::Helper

        module_function

        def init_request(request_id, ttl: default_ttl)
          cache_set(status_key(request_id), 'pending', ttl)
        end

        def complete(request_id, response:, meta:, ttl: default_ttl)
          write_response(request_id, response, ttl)
          cache_set(meta_key(request_id), Legion::JSON.dump(meta), ttl)
          cache_set(status_key(request_id), 'done', ttl)
        end

        def fail_request(request_id, code:, message:, ttl: default_ttl)
          log.warn("ResponseCache fail_request request_id=#{request_id} code=#{code} message=#{message}")
          payload = Legion::JSON.dump({ code: code, message: message })
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

        def poll(request_id, timeout: default_ttl, interval: 0.1)
          deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout

          loop do
            current = status(request_id)
            log.debug("ResponseCache poll request_id=#{request_id} status=#{current}")

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

        private_class_method def self.default_ttl
          Legion::LLM.settings.dig(:prompt_caching, :response_cache, :ttl_seconds) || 300
        end

        private_class_method def self.spool_threshold
          Legion::LLM.settings.dig(:prompt_caching, :response_cache, :spool_threshold_bytes) || 8 * 1024 * 1024
        end

        private_class_method def self.spool_dir
          configured = Legion::LLM.settings.dig(:prompt_caching, :response_cache, :spool_dir).to_s.strip
          configured.empty? ? File.expand_path('~/.legionio/data/spool/llm_responses') : File.expand_path(configured)
        end

        private_class_method def self.write_response(request_id, response_text, ttl)
          if response_text.bytesize > spool_threshold
            log.warn("ResponseCache spool overflow request_id=#{request_id} bytes=#{response_text.bytesize}")
            FileUtils.mkdir_p(spool_dir)
            path = File.join(spool_dir, "#{request_id}.txt")
            File.write(path, response_text)
            cache_set(response_key(request_id), "spool:#{path}", ttl)
          else
            cache_set(response_key(request_id), response_text, ttl)
          end
        end
      end
    end
  end
end
