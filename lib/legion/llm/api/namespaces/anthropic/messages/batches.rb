# frozen_string_literal: true

require 'securerandom'
require 'sinatra/base'
require 'sinatra/extension'
require 'sinatra/namespace'

module Legion
  module LLM
    module API
      module Namespaces
        module Anthropic
          module Messages
            module Batches
              extend Sinatra::Extension

              post '' do
                require_llm!
                body = parse_request_body

                unless body[:requests].is_a?(Array) && body[:requests].any?
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ type: 'error', error: { type: 'invalid_request_error', message: 'requests array is required' } })
                end

                batch_id = "batch_#{SecureRandom.hex(12)}"
                now = Time.now.utc.iso8601

                batch = {
                  id:                  batch_id,
                  type:                'message_batch',
                  processing_status:   'in_progress',
                  request_counts:      { processing: body[:requests].size, succeeded: 0, errored: 0, canceled: 0, expired: 0 },
                  created_at:          now,
                  ended_at:            nil,
                  expires_at:          (Time.now.utc + 86_400).iso8601,
                  cancel_initiated_at: nil,
                  results_url:         "/v1/messages/batches/#{batch_id}/results"
                }

                store_batch(batch_id, batch: batch, requests: body[:requests])

                content_type :json
                status 200
                Legion::JSON.dump(batch)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.batches.create')
                anthropic_error('api_error', e.message, status_code: 500)
              end
              get '' do
                require_llm!
                batches = list_batches(
                  limit:     (params[:limit] || 20).to_i,
                  before_id: params[:before_id],
                  after_id:  params[:after_id]
                )

                content_type :json
                Legion::JSON.dump(batches)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.batches.list')
                anthropic_error('api_error', e.message, status_code: 500)
              end

              get '/:id' do
                require_llm!
                batch = find_batch(params[:id])
                unless batch
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ type: 'error', error: { type: 'not_found_error', message: "Batch '#{params[:id]}' not found" } })
                end

                content_type :json
                Legion::JSON.dump(batch)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.batches.get')
                anthropic_error('api_error', e.message, status_code: 500)
              end

              get '/:id/results' do
                require_llm!
                batch = find_batch(params[:id])
                unless batch
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ type: 'error', error: { type: 'not_found_error', message: "Batch '#{params[:id]}' not found" } })
                end

                unless batch[:processing_status] == 'ended'
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ type: 'error', error: { type: 'invalid_request_error', message: 'Batch not yet complete' } })
                end

                content_type 'application/x-jsonl'
                results = batch_results(params[:id])
                results.map { |r| Legion::JSON.dump(r) }.join("\n")
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.batches.results')
                anthropic_error('api_error', e.message, status_code: 500)
              end

              post '/:id/cancel' do
                require_llm!
                batch = find_batch(params[:id])
                unless batch
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ type: 'error', error: { type: 'not_found_error', message: "Batch '#{params[:id]}' not found" } })
                end

                batch[:processing_status] = 'canceling'
                batch[:cancel_initiated_at] = Time.now.utc.iso8601
                update_batch(params[:id], batch)

                content_type :json
                Legion::JSON.dump(batch)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.batches.cancel')
                anthropic_error('api_error', e.message, status_code: 500)
              end

              delete '/:id' do
                require_llm!
                batch = find_batch(params[:id])
                unless batch
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ type: 'error', error: { type: 'not_found_error', message: "Batch '#{params[:id]}' not found" } })
                end

                unless %w[ended canceled expired].include?(batch[:processing_status])
                  halt 409, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ type: 'error', error: { type: 'invalid_request_error', message: 'Cannot delete batch that is still processing' } })
                end

                delete_batch(params[:id])
                content_type :json
                Legion::JSON.dump({ id: params[:id], type: 'message_batch', deleted: true })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.batches.delete')
                anthropic_error('api_error', e.message, status_code: 500)
              end

              helpers do
                def store_batch(id, batch:, requests:)
                  batch_store[id] = { batch: batch, requests: requests, results: [] }
                end

                def find_batch(id)
                  entry = batch_store[id]
                  entry ? entry[:batch] : nil
                end

                def update_batch(id, batch)
                  batch_store[id][:batch] = batch if batch_store[id]
                end

                def delete_batch(id)
                  batch_store.delete(id)
                end

                # rubocop:disable Lint/UnusedMethodArgument
                def list_batches(limit:, before_id: nil, after_id: nil)
                  all = batch_store.values.map { |e| e[:batch] }.sort_by { |b| b[:created_at] }.reverse
                  all = all.first(limit.clamp(1, 100))
                  { data: all, has_more: false, first_id: all.first&.dig(:id), last_id: all.last&.dig(:id) }
                end
                # rubocop:enable Lint/UnusedMethodArgument

                def batch_results(id)
                  batch_store.dig(id, :results) || []
                end

                def batch_store
                  @batch_store ||= {}
                end
              end
            end
          end
        end
      end
    end
  end
end
