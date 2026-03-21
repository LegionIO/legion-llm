# frozen_string_literal: true

require 'securerandom'

module Legion
  module LLM
    module Batch
      class << self
        # Returns true when request batching is enabled in settings.
        def enabled?
          settings.fetch(:enabled, false) == true
        end

        # Enqueues a request for deferred batch processing.
        #
        # @param messages [Array<Hash>] chat messages array
        # @param model    [String]      model to use
        # @param provider [Symbol, nil] provider override
        # @param callback [Proc, nil]   called with result hash when batch is flushed
        # @param priority [Symbol]      :normal or :low (informational only)
        # @param opts     [Hash]        additional options forwarded to provider
        # @return [String] batch_request_id
        def enqueue(messages:, model:, callback: nil, provider: nil, priority: :normal, **opts)
          request_id = SecureRandom.uuid

          entry = {
            id:        request_id,
            messages:  messages,
            model:     model,
            provider:  provider,
            callback:  callback,
            priority:  priority,
            opts:      opts,
            queued_at: Time.now.utc
          }

          queue << entry
          Legion::Logging.debug "Legion::LLM::Batch enqueued #{request_id} (queue size: #{queue.size})"
          request_id
        end

        # Flushes accumulated requests up to max_size.
        # Groups entries by provider+model and invokes callbacks with a stub result.
        # In production this would submit to provider batch APIs; here it logs and returns
        # per-request result hashes for callback delivery.
        #
        # @param max_size [Integer] maximum number of requests to flush in one pass
        # @param max_wait [Integer] only flush entries older than this many seconds (0 = all)
        # @return [Array<Hash>] array of { id:, status:, result: } hashes
        def flush(max_size: nil, max_wait: nil)
          effective_max  = max_size || settings.fetch(:max_batch_size, 100)
          effective_wait = max_wait || settings.fetch(:window_seconds, 300)

          cutoff = Time.now.utc - effective_wait
          to_flush = queue.select { |e| e[:queued_at] <= cutoff }.first(effective_max)

          return [] if to_flush.empty?

          to_flush.each { |e| queue.delete(e) }
          Legion::Logging.debug "Legion::LLM::Batch flushing #{to_flush.size} request(s)"

          groups = to_flush.group_by { |e| [e[:provider], e[:model]] }
          results = []

          groups.each do |(provider, model), entries|
            entries.each do |entry|
              result = submit_single(entry, provider: provider, model: model)
              entry[:callback]&.call(result)
              results << { id: entry[:id], status: result[:status], result: result }
            end
          end

          results
        end

        # Returns the current number of requests in the queue.
        def queue_size
          queue.size
        end

        # Clears the queue (useful for testing).
        def reset!
          @queue = []
        end

        private

        def queue
          @queue ||= []
        end

        def settings
          llm = Legion::Settings[:llm]
          return {} unless llm.is_a?(Hash)

          b = llm[:batch] || llm['batch'] || {}
          b.is_a?(Hash) ? b.transform_keys(&:to_sym) : {}
        rescue StandardError
          {}
        end

        def submit_single(entry, provider:, model:)
          {
            status:   :batched,
            model:    model,
            provider: provider,
            id:       entry[:id],
            response: nil,
            meta:     { batched: true, queued_at: entry[:queued_at] }
          }
        end
      end
    end
  end
end
