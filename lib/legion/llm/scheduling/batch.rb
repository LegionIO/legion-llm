# frozen_string_literal: true

require 'securerandom'

require 'legion/logging/helper'
module Legion
  module LLM
    module Scheduling
      module Batch
        extend Legion::Logging::Helper

        @mutex = Mutex.new
        @flush_timer = nil

        class << self
          def enabled?
            settings.fetch(:enabled, false) == true
          end

          def enqueue(messages: nil, model: nil, message: nil, callback: nil, provider: nil, priority: :normal, **opts)
            request_id = SecureRandom.uuid
            msgs = messages || (message ? [{ role: 'user', content: message }] : [])

            entry = {
              id:        request_id,
              messages:  msgs,
              model:     model,
              provider:  provider,
              callback:  callback,
              priority:  priority,
              opts:      opts,
              queued_at: Time.now.utc
            }

            @mutex.synchronize { queue << entry }
            ensure_flush_timer
            log.debug "Legion::LLM::Batch enqueued #{request_id} (queue size: #{queue_size})"
            request_id
          end

          def flush(max_size: nil, max_wait: nil)
            effective_max  = max_size || settings.fetch(:max_batch_size, 100)
            effective_wait = max_wait || settings.fetch(:window_seconds, 300)
            cutoff = Time.now.utc - effective_wait

            to_flush = @mutex.synchronize do
              ready = queue.select { |e| e[:queued_at] <= cutoff }
                           .sort_by { |e| priority_rank(e[:priority]) }
                           .first(effective_max)
              ready.each { |e| queue.delete(e) }
              ready
            end

            return [] if to_flush.empty?

            log.debug "Legion::LLM::Batch flushing #{to_flush.size} request(s)"

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

          def queue_size
            @mutex.synchronize { queue.size }
          end

          def status
            entries = @mutex.synchronize { queue.dup }
            oldest = entries.min_by { |e| e[:queued_at] }
            {
              enabled:        enabled?,
              queue_size:     entries.size,
              max_batch_size: settings.fetch(:max_batch_size, 100),
              window_seconds: settings.fetch(:window_seconds, 300),
              oldest_queued:  oldest ? oldest[:queued_at].iso8601 : nil,
              by_priority:    entries.group_by { |e| e[:priority] }.transform_values(&:size)
            }
          end

          def reset!
            @mutex.synchronize { @queue = [] }
            stop_flush_timer
          end

          def stop_flush_timer
            @flush_timer&.shutdown if @flush_timer.respond_to?(:shutdown)
            @flush_timer = nil
          end

          private

          def queue
            @queue ||= []
          end

          def priority_rank(priority)
            case priority.to_sym
            when :urgent then 0
            when :normal then 1
            when :low    then 2
            else 3
            end
          end

          def ensure_flush_timer
            return if @flush_timer
            return unless defined?(Concurrent::TimerTask)

            interval = settings.fetch(:window_seconds, 300)
            return if interval <= 0

            @flush_timer = Concurrent::TimerTask.new(execution_interval: interval) do
              flush(max_wait: 0)
            rescue StandardError => e
              handle_exception(e, level: :warn)
            end
            @flush_timer.execute
          end

          def settings
            llm = Legion::Settings[:llm]
            return {} unless llm.is_a?(Hash)

            b = llm[:batch] || llm['batch'] || {}
            b.is_a?(Hash) ? b.transform_keys(&:to_sym) : {}
          rescue StandardError => e
            handle_exception(e, level: :warn)
            {}
          end

          def submit_single(entry, provider:, model:)
            msgs = entry[:messages]
            prompt = if msgs.is_a?(Array)
                       last_user = msgs.select { |m| (m[:role] || m['role']).to_s == 'user' }.last
                       (last_user || {}).fetch(:content, nil) || (last_user || {}).fetch('content', nil) || ''
                     else
                       msgs.to_s
                     end
            response = Legion::LLM.chat_direct(
              **entry[:opts],
              provider: provider,
              model:    model,
              message:  prompt,
              urgency:  :immediate
            )

            {
              status:   response.is_a?(Hash) && response[:deferred] ? :deferred : :completed,
              model:    model,
              provider: provider,
              id:       entry[:id],
              response: response,
              meta:     { batched: true, queued_at: entry[:queued_at], completed_at: Time.now.utc }
            }
          rescue StandardError => e
            handle_exception(e, level: :warn)
            {
              status:   :failed,
              model:    model,
              provider: provider,
              id:       entry[:id],
              response: nil,
              error:    e.message,
              meta:     { batched: true, queued_at: entry[:queued_at], failed_at: Time.now.utc }
            }
          end
        end
      end
    end
  end
end
