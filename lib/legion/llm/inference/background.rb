# frozen_string_literal: true

require 'concurrent'
require 'legion/logging/helper'

module Legion
  module LLM
    module Inference
      # Admission is bounded and never executes work on the submitting thread.
      # Keyed jobs retain only the latest pending task for an admitted key.
      class Background
        include Legion::Logging::Helper

        @shared_mutex = Mutex.new

        class << self
          def shared
            @shared_mutex.synchronize { @shared ||= new }
          end

          def post(...)
            shared.post(...)
          end

          def stats
            @shared_mutex.synchronize do
              @shared ? @shared.stats : { state: :idle, queue_length: 0 }
            end
          end

          def shutdown
            shared.shutdown
          end

          def start
            @shared_mutex.synchronize do
              return if @shared.nil? || @shared.running?

              raise 'inference background jobs are still draining' unless @shared.terminated?

              @shared = nil
            end
          end
        end

        def initialize
          @workers = Legion::Settings[:llm][:background][:workers]
          @capacity = Legion::Settings[:llm][:background][:max_queue]
          @shutdown_timeout = Legion::Settings[:llm][:background][:shutdown_timeout]
          raise ArgumentError, 'llm.background.workers must be a positive integer' unless @workers.is_a?(Integer) && @workers.positive?
          raise ArgumentError, 'llm.background.max_queue must be a positive integer' unless @capacity.is_a?(Integer) && @capacity.positive?
          unless @shutdown_timeout.is_a?(Numeric) && @shutdown_timeout.real? && @shutdown_timeout.finite? && @shutdown_timeout >= 0
            raise ArgumentError, 'llm.background.shutdown_timeout must be finite and nonnegative'
          end

          @pool = Concurrent::FixedThreadPool.new(@workers, max_queue: @capacity, fallback_policy: :abort, auto_terminate: false)
          @mutex = Mutex.new
          @keyed = {}
          @deferred = []
          @admitted = 0
          @rejected = 0
          @coalesced = 0
          @stopping = false
        end

        def post(workload:, key: nil, **, &task)
          raise ArgumentError, 'background work requires a block' unless task

          @mutex.synchronize do
            return reject(workload, :shutdown) if @stopping

            identity = [workload, key] unless key.nil?
            if identity && (job = @keyed[identity])
              job[:pending] = task
              @coalesced += 1
              return true
            end

            return reject(workload, :capacity) if @admitted >= @workers + @capacity

            job = { pending: task, identity: identity, workload: workload }
            @keyed[identity] = job if identity
            begin
              enqueue(job)
              @admitted += 1
            rescue Concurrent::RejectedExecutionError => e
              @keyed.delete(identity) if identity
              handle_exception(e, level: :warn, operation: 'llm.background.admission', workload: workload)
              return reject(workload, :capacity)
            end
            true
          end
        end

        def stats
          @mutex.synchronize do
            {
              state: @stopping ? :stopping : :running,
              workers: @workers, max_queue: @capacity, queue_length: @pool.queue_length,
              admitted_jobs: @admitted, deferred_jobs: @deferred.size,
              keyed_jobs: @keyed.size, rejected_jobs: @rejected, coalesced_jobs: @coalesced,
              completed_jobs: @pool.completed_task_count
            }
          end
        end

        def running?
          @mutex.synchronize { !@stopping }
        end

        def terminated?
          @pool.wait_for_termination(0)
        end

        def shutdown
          @mutex.synchronize do
            @stopping = true
            @pool.shutdown if @admitted.zero?
          end
          drained = @pool.wait_for_termination(@shutdown_timeout)
          log.info "[llm][background] action=shutdown drained=#{drained} queue_length=#{@pool.queue_length}"
          log.warn '[llm][background] action=shutdown_timeout policy=continue_draining' unless drained
          drained
        end

        private

        def enqueue(job)
          @pool.post { run(job) }
        end

        def reject(workload, reason)
          @rejected += 1
          log.warn "[llm][background] action=rejected workload=#{workload} reason=#{reason} queue_length=#{@pool.queue_length} max_queue=#{@capacity}"
          false
        end

        def run(job)
          task = @mutex.synchronize do
            # Starting a queued job frees a native queue slot. Deferred follow-ups
            # go to its tail, rather than monopolizing this worker in a loop.
            dispatch_deferred
            pending = job[:pending]
            job[:pending] = nil
            pending
          end
          task.call
        rescue NotImplementedError, NoMethodError, ArgumentError, TypeError
          raise
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.background.execute', workload: job[:workload])
        ensure
          @mutex.synchronize do
            if job[:pending]
              @deferred << job
            else
              @keyed.delete(job[:identity]) if job[:identity]
              @admitted -= 1
            end
            dispatch_deferred
            @pool.shutdown if @stopping && @admitted.zero?
          end
        end

        def dispatch_deferred
          @deferred.size.times do
            job = @deferred.first
            begin
              enqueue(job)
            rescue Concurrent::RejectedExecutionError => e
              # Bounded pending keys remain recoverable; the next queued job
              # starts dispatching them as soon as a native queue slot opens.
              handle_exception(e, level: :warn, operation: 'llm.background.defer', workload: job[:workload])
              break
            end
            @deferred.shift
          end
        end

        at_exit { @shared&.shutdown }
      end
    end
  end
end
