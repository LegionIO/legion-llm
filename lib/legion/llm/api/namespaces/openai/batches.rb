# frozen_string_literal: true

require 'securerandom'
require 'concurrent'
require 'legion/logging/helper'
require 'legion/llm/api/namespaces/helpers'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Batches
            extend Legion::Logging::Helper

            BATCH_STORE = {} # rubocop:disable Style/MutableConstant
            BATCH_MUTEX = Mutex.new
            BATCH_POOL_MUTEX = Mutex.new
            @batch_pool = nil

            def self.batch_pool
              return @batch_pool if @batch_pool

              BATCH_POOL_MUTEX.synchronize do
                @batch_pool ||= begin
                  pool_size = Legion::Settings[:llm][:api][:batch_pool_size]
                  Concurrent::FixedThreadPool.new(pool_size, fallback_policy: :caller_runs)
                end
              end
            end

            def self.registered(app) # rubocop:disable Metrics/AbcSize
              log.debug('[llm][api][namespaces][openai][batches] registering routes')

              # POST /v1/batches
              app.post '/v1/batches' do
                require_llm!
                body = parse_request_body
                validate_required!(body, :input_file_id, :endpoint)

                batch_id = "batch_#{SecureRandom.hex(16)}"
                endpoint = body[:endpoint].to_s
                file_id  = body[:input_file_id].to_s
                window   = body[:completion_window] || '24h'
                metadata = body[:metadata] || {}

                caller_context = build_server_caller(source: 'openai_batch', path: request.path, env: env)

                entry = {
                  id:                batch_id,
                  object:            'batch',
                  endpoint:          endpoint,
                  errors:            nil,
                  input_file_id:     file_id,
                  completion_window: window,
                  status:            :validating,
                  output_file_id:    nil,
                  error_file_id:     nil,
                  created_at:        Time.now,
                  in_progress_at:    nil,
                  expires_at:        Time.now + 86_400,
                  finalizing_at:     nil,
                  completed_at:      nil,
                  failed_at:         nil,
                  expired_at:        nil,
                  cancelling_at:     nil,
                  cancelled_at:      nil,
                  request_counts:    { total: 0, completed: 0, failed: 0 },
                  metadata:          metadata,
                  results:           [],
                  caller_context:    caller_context
                }

                BATCH_MUTEX.synchronize { BATCH_STORE[batch_id] = entry }
                log.debug("[llm][api][openai][batches] action=create batch_id=#{batch_id} endpoint=#{endpoint} file_id=#{file_id}")

                begin
                  Batches.batch_pool.post { Batches.process_batch(batch_id) }
                rescue Concurrent::RejectedExecutionError
                  BATCH_MUTEX.synchronize { BATCH_STORE.delete(batch_id) }
                  log.warn("[llm][api][openai][batches] action=queue_full batch_id=#{batch_id}")
                  halt 503, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: 'Batch queue is full. Retry after existing batches complete.',
                                                    type: 'server_error', code: 'batch_queue_full' } })
                end

                content_type :json
                status 200
                Legion::JSON.dump(Batches.serialize_batch(entry))
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.batches.create')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # GET /v1/batches (list)
              app.get '/v1/batches' do
                require_llm!
                limit = params[:limit]&.to_i || 20
                after = params[:after]

                entries = BATCH_MUTEX.synchronize { BATCH_STORE.values.dup }
                entries.sort_by! { |b| -b[:created_at].to_i }

                if after
                  idx     = entries.index { |b| b[:id] == after }
                  entries = entries[(idx + 1)..] if idx
                end

                entries = entries.first(limit)
                log.debug("[llm][api][openai][batches] action=list count=#{entries.size}")

                content_type :json
                status 200
                Legion::JSON.dump({
                                    object:   'list',
                                    data:     entries.map { |b| Batches.serialize_batch(b) },
                                    has_more: false,
                                    first_id: entries.first&.dig(:id),
                                    last_id:  entries.last&.dig(:id)
                                  })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.batches.list')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # GET /v1/batches/:id
              app.get '/v1/batches/:id' do
                require_llm!
                batch_id = params[:id]
                entry    = BATCH_MUTEX.synchronize { BATCH_STORE[batch_id] }

                unless entry
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "Batch '#{batch_id}' not found.",
                                                    type: 'invalid_request_error', code: 'batch_not_found' } })
                end

                log.debug("[llm][api][openai][batches] action=get batch_id=#{batch_id} status=#{entry[:status]}")
                content_type :json
                status 200
                Legion::JSON.dump(Batches.serialize_batch(entry))
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.batches.get')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # POST /v1/batches/:id/cancel
              app.post '/v1/batches/:id/cancel' do
                require_llm!
                batch_id = params[:id]
                entry    = BATCH_MUTEX.synchronize { BATCH_STORE[batch_id] }

                unless entry
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "Batch '#{batch_id}' not found.",
                                                    type: 'invalid_request_error', code: 'batch_not_found' } })
                end

                BATCH_MUTEX.synchronize do
                  BATCH_STORE[batch_id][:status]        = :cancelling
                  BATCH_STORE[batch_id][:cancelling_at] = Time.now
                end

                log.debug("[llm][api][openai][batches] action=cancel batch_id=#{batch_id}")
                content_type :json
                status 200
                Legion::JSON.dump(Batches.serialize_batch(BATCH_MUTEX.synchronize { BATCH_STORE[batch_id] }))
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.batches.cancel')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              log.debug('[llm][api][namespaces][openai][batches] routes registered')
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.batches.register')
            end

            # Class-level batch processor (called from thread pool)
            def self.process_batch(batch_id)
              entry = BATCH_MUTEX.synchronize { BATCH_STORE[batch_id]&.dup }
              return unless entry

              extend Legion::Logging::Helper

              BATCH_MUTEX.synchronize do
                BATCH_STORE[batch_id][:status]         = :in_progress
                BATCH_STORE[batch_id][:in_progress_at] = Time.now
              end

              file_id  = entry[:input_file_id]
              requests = load_batch_requests(file_id)

              BATCH_MUTEX.synchronize do
                BATCH_STORE[batch_id][:request_counts][:total] = requests.size
              end

              caller_ctx = BATCH_MUTEX.synchronize { BATCH_STORE[batch_id]&.dig(:caller_context) } || {}

              results = requests.map do |req|
                cancelled = BATCH_MUTEX.synchronize { BATCH_STORE[batch_id]&.dig(:status) == :cancelling }
                break [] if cancelled

                dispatch_batch_request(batch_id, req, caller_context: caller_ctx)
              end.flatten.compact

              cancelled = BATCH_MUTEX.synchronize { BATCH_STORE[batch_id]&.dig(:status) == :cancelling }

              BATCH_MUTEX.synchronize do
                next unless BATCH_STORE[batch_id]

                if cancelled
                  BATCH_STORE[batch_id][:status]       = :cancelled
                  BATCH_STORE[batch_id][:cancelled_at] = Time.now
                else
                  completed_count = results.count { |r| r[:response] }
                  failed_count    = results.count { |r| r[:error] }
                  BATCH_STORE[batch_id][:status]       = :completed
                  BATCH_STORE[batch_id][:completed_at] = Time.now
                  BATCH_STORE[batch_id][:results]      = results
                  BATCH_STORE[batch_id][:request_counts][:completed] = completed_count
                  BATCH_STORE[batch_id][:request_counts][:failed]    = failed_count
                end
              end
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: "llm.api.openai.batches.process.#{batch_id}")
              BATCH_MUTEX.synchronize do
                next unless BATCH_STORE[batch_id]

                BATCH_STORE[batch_id][:status]    = :failed
                BATCH_STORE[batch_id][:failed_at] = Time.now
              end
            end

            def self.load_batch_requests(file_id)
              file_path = ::File.join(Batches.files_dir, file_id)
              return [] unless ::File.exist?(file_path)

              ::File.readlines(file_path).filter_map do |line|
                Legion::JSON.load(line.strip)
              rescue StandardError => e
                log.debug "[llm][api][openai][batches] action=load_batch_line_fallback file=#{file_id} error=#{e.class} message=#{e.message}"
                nil
              end
            end

            def self.dispatch_batch_request(batch_id, req, caller_context: {})
              custom_id = req[:custom_id] || req['custom_id'] || SecureRandom.uuid
              body      = req[:body] || req['body'] || {}
              messages  = body[:messages] || body['messages'] || []
              # SSOT v3: each batch item builds its own Request/seed/RoutingSession via
              # the Executor. An omitted item model is an empty constraint the router
              # resolves — never a literal 'default'.
              model     = body[:model] || body['model']

              effective_caller = caller_context.empty? ? { source: 'openai_batch', path: "/v1/batches/#{batch_id}" } : caller_context

              inference_request = Legion::LLM::Inference::Request.build(
                messages: messages,
                routing:  (model ? { model: model } : {}),
                caller:   effective_caller
              )

              executor = Legion::LLM::Inference::Executor.new(inference_request)
              response = executor.call

              log.debug("[llm][api][openai][batches] batch_id=#{batch_id} custom_id=#{custom_id} status=success")
              {
                custom_id: custom_id,
                response:  {
                  status_code: 200,
                  body:        { choices: [{ message: response&.message }] }
                }
              }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: "llm.api.openai.batches.request.#{custom_id}")
              {
                custom_id: custom_id,
                error:     { code: 'server_error', message: e.message }
              }
            end

            def self.files_dir
              ::File.join(::Dir.home, '.legionio', 'data', 'files')
            end

            def self.serialize_batch(entry)
              {
                id:                entry[:id],
                object:            'batch',
                endpoint:          entry[:endpoint],
                errors:            entry[:errors],
                input_file_id:     entry[:input_file_id],
                completion_window: entry[:completion_window],
                status:            entry[:status].to_s,
                output_file_id:    entry[:output_file_id],
                error_file_id:     entry[:error_file_id],
                created_at:        entry[:created_at]&.to_i,
                in_progress_at:    entry[:in_progress_at]&.to_i,
                expires_at:        entry[:expires_at]&.to_i,
                finalizing_at:     entry[:finalizing_at]&.to_i,
                completed_at:      entry[:completed_at]&.to_i,
                failed_at:         entry[:failed_at]&.to_i,
                expired_at:        entry[:expired_at]&.to_i,
                cancelling_at:     entry[:cancelling_at]&.to_i,
                cancelled_at:      entry[:cancelled_at]&.to_i,
                request_counts:    entry[:request_counts],
                metadata:          entry[:metadata]
              }.compact
            end
          end
        end
      end
    end
  end
end
