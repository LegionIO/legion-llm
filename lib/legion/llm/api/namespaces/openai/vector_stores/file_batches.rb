# frozen_string_literal: true

require 'sequel'
require 'sinatra/extension'
require 'sinatra/namespace'
require 'legion/json'
require 'legion/logging/helper'
require 'legion/llm/call/embeddings'
require 'legion/llm/vector_store/storage'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module VectorStores
            module FileBatches
              extend Sinatra::Extension
              extend Legion::Logging::Helper

              SYNC_BATCH_LIMIT = 20

              # POST /v1/vector_stores/:vector_store_id/file_batches — create batch
              # rubocop:disable Metrics/BlockLength
              post '/file_batches' do
                require_llm!
                require_data!
                Legion::LLM::VectorStore::Storage.ensure_tables!
                body = parse_request_body

                validate_required!(body, :file_ids)

                unless body[:file_ids].is_a?(Array)
                  return openai_error('file_ids must be an array',
                                      type: 'invalid_request_error', code: 'invalid_file_ids', status_code: 400)
                end

                store_id = params[:vector_store_id]
                store = Legion::LLM::VectorStore::Storage.db[:llm_vector_stores].where(id: store_id).first
                unless store
                  return openai_error("No vector_store found with id '#{store_id}'",
                                      type: 'invalid_request_error', code: 'not_found', status_code: 404)
                end

                file_ids      = body[:file_ids].map(&:to_s).uniq.first(SYNC_BATCH_LIMIT)
                batch_id      = Legion::LLM::VectorStore::Storage.generate_id('vsfb')
                ts            = Legion::LLM::VectorStore::Storage.now_ts
                initial_counts = {
                  in_progress: file_ids.size,
                  completed:   0,
                  failed:      0,
                  cancelled:   0,
                  total:       file_ids.size
                }

                Legion::LLM::VectorStore::Storage.db[:llm_vector_store_batches].insert(
                  id:               batch_id,
                  vector_store_id:  store_id,
                  status:           'in_progress',
                  file_ids_json:    Legion::JSON.dump(file_ids),
                  file_counts_json: Legion::JSON.dump(initial_counts),
                  created_at:       ts
                )

                log.debug("[llm][api][vector_stores][batches] action=create batch_id=#{batch_id} " \
                          "store_id=#{store_id} file_count=#{file_ids.size}")

                counts = process_batch_files(batch_id, store_id, file_ids, body[:chunking_strategy])

                final_status = counts[:failed].positive? && counts[:completed].zero? ? 'failed' : 'completed'
                Legion::LLM::VectorStore::Storage.db[:llm_vector_store_batches]
                                                 .where(id: batch_id)
                                                 .update(status: final_status, file_counts_json: Legion::JSON.dump(counts))

                batch_row = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_batches].where(id: batch_id).first

                content_type :json
                status 200
                Legion::JSON.dump(format_batch(batch_row))
              rescue StandardError => e
                handle_exception(e, level: :error, operation: 'llm.api.vector_stores.batches.create')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end
              # rubocop:enable Metrics/BlockLength

              # GET /v1/vector_stores/:vector_store_id/file_batches/:batch_id — retrieve status
              get '/file_batches/:batch_id' do
                require_llm!
                require_data!
                Legion::LLM::VectorStore::Storage.ensure_tables!

                row = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_batches]
                                                       .where(id: params[:batch_id], vector_store_id: params[:vector_store_id])
                                                       .first
                unless row
                  return openai_error("No vector_store.file_batch found with id '#{params[:batch_id]}'",
                                      type: 'invalid_request_error', code: 'not_found', status_code: 404)
                end

                log.debug("[llm][api][vector_stores][batches] action=retrieve batch_id=#{params[:batch_id]}")

                content_type :json
                status 200
                Legion::JSON.dump(format_batch(row))
              rescue StandardError => e
                handle_exception(e, level: :error, operation: 'llm.api.vector_stores.batches.retrieve')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # GET /v1/vector_stores/:vector_store_id/file_batches/:batch_id/files — list files in batch
              get '/file_batches/:batch_id/files' do
                require_llm!
                require_data!
                Legion::LLM::VectorStore::Storage.ensure_tables!

                batch_row = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_batches]
                                                             .where(id: params[:batch_id], vector_store_id: params[:vector_store_id])
                                                             .first
                unless batch_row
                  return openai_error("No vector_store.file_batch found with id '#{params[:batch_id]}'",
                                      type: 'invalid_request_error', code: 'not_found', status_code: 404)
                end

                file_ids = Legion::JSON.load(batch_row[:file_ids_json] || '[]')
                filter   = params[:filter]
                limit    = [params[:limit].to_i.then { |v| v.positive? ? v : 20 }, 100].min

                ds = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files]
                                                      .where(vector_store_id: params[:vector_store_id], file_id: file_ids)
                                                      .order(::Sequel.desc(:created_at))
                                                      .limit(limit)
                ds = ds.where(status: filter) if filter

                rows = ds.all
                log.debug("[llm][api][vector_stores][batches] action=list_files batch_id=#{params[:batch_id]} count=#{rows.size}")

                content_type :json
                status 200
                Legion::JSON.dump({
                                    object:   'list',
                                    data:     rows.map { |r| format_vsf(r) },
                                    has_more: false,
                                    first_id: rows.first&.dig(:id),
                                    last_id:  rows.last&.dig(:id)
                                  })
              rescue StandardError => e
                handle_exception(e, level: :error, operation: 'llm.api.vector_stores.batches.list_files')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end
              # POST /v1/vector_stores/:vector_store_id/file_batches/:batch_id/cancel
              post '/file_batches/:batch_id/cancel' do
                require_llm!
                require_data!
                Legion::LLM::VectorStore::Storage.ensure_tables!

                row = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_batches]
                                                       .where(id: params[:batch_id], vector_store_id: params[:vector_store_id])
                                                       .first
                unless row
                  return openai_error("No vector_store.file_batch found with id '#{params[:batch_id]}'",
                                      type: 'invalid_request_error', code: 'not_found', status_code: 404)
                end

                unless row[:status] == 'in_progress'
                  return openai_error("File batch '#{params[:batch_id]}' has status '#{row[:status]}' and cannot be cancelled",
                                      type: 'invalid_request_error', code: 'batch_not_cancellable', status_code: 400)
                end

                Legion::LLM::VectorStore::Storage.db[:llm_vector_store_batches]
                                                 .where(id: params[:batch_id])
                                                 .update(status: 'cancelled')

                row = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_batches].where(id: params[:batch_id]).first

                log.debug("[llm][api][vector_stores][batches] action=cancel batch_id=#{params[:batch_id]}")

                content_type :json
                status 200
                Legion::JSON.dump(format_batch(row))
              rescue StandardError => e
                handle_exception(e, level: :error, operation: 'llm.api.vector_stores.batches.cancel')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              def process_batch_files(_batch_id, store_id, file_ids, chunking_strategy)
                counts = { in_progress: 0, completed: 0, failed: 0, cancelled: 0, total: file_ids.size }
                chunking_json = chunking_strategy.is_a?(Hash) ? Legion::JSON.dump(chunking_strategy) : '{"type":"auto"}'
                ts = Legion::LLM::VectorStore::Storage.now_ts

                file_ids.each do |file_id|
                  vsf_id  = Legion::LLM::VectorStore::Storage.generate_id('vsf')
                  status  = 'in_progress'
                  usage   = 0

                  content_text = fetch_file_content(file_id)

                  if content_text
                    chunks        = Legion::LLM::VectorStore::Storage.chunk_text(content_text)
                    embed_results = Legion::LLM::Call::Embeddings.generate_batch(texts: chunks, task: :document)
                    store_chunks(vsf_id, store_id, file_id, chunks, embed_results)
                    status = 'completed'
                    usage  = content_text.bytesize
                    counts[:completed] += 1
                  else
                    counts[:in_progress] += 1
                  end

                  Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files].insert(
                    id:                     vsf_id,
                    vector_store_id:        store_id,
                    file_id:                file_id,
                    status:                 status,
                    usage_bytes:            usage,
                    chunking_strategy_json: chunking_json,
                    attributes_json:        '{}',
                    last_error_json:        nil,
                    created_at:             ts
                  )
                rescue StandardError => e
                  handle_exception(e, level: :warn, handled: true,
                                   operation: "llm.api.vector_stores.batches.process_file.#{file_id}")
                  counts[:failed] += 1
                end

                counts
              end

              def fetch_file_content(file_id)
                return nil unless Legion::LLM::VectorStore::Storage.data_available?
                return nil unless Legion::LLM::VectorStore::Storage.db.table_exists?(:llm_files)

                Legion::LLM::VectorStore::Storage.db[:llm_files].where(id: file_id).first&.dig(:content)
              rescue StandardError => e
                handle_exception(e, level: :warn, handled: true,
                                 operation: "llm.api.vector_stores.batches.fetch_content.#{file_id}")
                nil
              end

              def store_chunks(vsf_id, store_id, file_id, chunks, embed_results)
                ts = Legion::LLM::VectorStore::Storage.now_ts
                chunks.each_with_index do |chunk, index|
                  result = embed_results[index] || {}
                  vec    = result[:vector]
                  Legion::LLM::VectorStore::Storage.db[:llm_vector_store_chunks].insert(
                    id:                   Legion::LLM::VectorStore::Storage.generate_id('vsc'),
                    vector_store_id:      store_id,
                    vector_store_file_id: vsf_id,
                    file_id:              file_id,
                    chunk_index:          index,
                    text:                 chunk,
                    embedding_json:       vec ? Legion::JSON.dump(vec) : nil,
                    created_at:           ts
                  )
                end
              end

              def format_batch(row)
                return nil unless row

                counts = Legion::JSON.load(row[:file_counts_json] || '{}')
                counts = { in_progress: 0, completed: 0, failed: 0, cancelled: 0, total: 0 }.merge(counts)

                {
                  id:              row[:id],
                  object:          'vector_store.file_batch',
                  vector_store_id: row[:vector_store_id],
                  status:          row[:status].to_s,
                  file_counts:     counts,
                  created_at:      row[:created_at].to_i
                }
              end

              def format_vsf(row)
                return nil unless row

                {
                  id:                row[:id],
                  object:            'vector_store.file',
                  vector_store_id:   row[:vector_store_id],
                  file_id:           row[:file_id],
                  status:            row[:status].to_s,
                  usage_bytes:       row[:usage_bytes].to_i,
                  created_at:        row[:created_at].to_i,
                  chunking_strategy: Legion::JSON.load(row[:chunking_strategy_json] || '{"type":"auto"}'),
                  last_error:        row[:last_error_json] ? Legion::JSON.load(row[:last_error_json]) : nil,
                  attributes:        Legion::JSON.load(row[:attributes_json] || '{}')
                }
              end
            end
          end
        end
      end
    end
  end
end
