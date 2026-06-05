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
            module Files
              extend Sinatra::Extension
              extend Legion::Logging::Helper

              # POST /v1/vector_stores/:vector_store_id/files — attach file + embed
              post '/files' do
                require_llm!
                require_data!
                Legion::LLM::VectorStore::Storage.ensure_tables!
                body = parse_request_body
                validate_required!(body, :file_id)

                store_id = params[:vector_store_id]
                store = Legion::LLM::VectorStore::Storage.db[:llm_vector_stores].where(id: store_id).first
                unless store
                  return openai_error("No vector_store found with id '#{store_id}'",
                                      type: 'invalid_request_error', code: 'not_found', status_code: 404)
                end

                file_id    = body[:file_id].to_s
                vsf_id     = Legion::LLM::VectorStore::Storage.generate_id('vsf')
                ts         = Legion::LLM::VectorStore::Storage.now_ts
                chunking   = body[:chunking_strategy].is_a?(Hash) ? Legion::JSON.dump(body[:chunking_strategy]) : '{"type":"auto"}'
                attributes = body[:attributes].is_a?(Hash) ? Legion::JSON.dump(body[:attributes]) : '{}'

                content_text = fetch_file_content(file_id)
                status_val   = 'in_progress'
                usage_bytes  = 0

                if content_text
                  chunks = Legion::LLM::VectorStore::Storage.chunk_text(content_text)
                  embed_results = Legion::LLM::Call::Embeddings.generate_batch(
                    texts: chunks,
                    task:  :document
                  )
                  store_chunks(vsf_id, store_id, file_id, chunks, embed_results)
                  status_val  = 'completed'
                  usage_bytes = content_text.bytesize
                end

                Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files].insert(
                  id:                     vsf_id,
                  vector_store_id:        store_id,
                  file_id:                file_id,
                  status:                 status_val,
                  usage_bytes:            usage_bytes,
                  chunking_strategy_json: chunking,
                  attributes_json:        attributes,
                  last_error_json:        nil,
                  created_at:             ts
                )

                log.debug("[llm][api][vector_stores][files] action=attach vsf_id=#{vsf_id} " \
                          "store_id=#{store_id} file_id=#{file_id} status=#{status_val}")

                row = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files].where(id: vsf_id).first

                content_type :json
                status 200
                Legion::JSON.dump(format_vsf(row))
              rescue StandardError => e
                handle_exception(e, level: :error, operation: 'llm.api.vector_stores.files.attach')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end
              # GET /v1/vector_stores/:vector_store_id/files — list attached files
              get '/files' do
                require_llm!
                require_data!
                Legion::LLM::VectorStore::Storage.ensure_tables!

                store_id = params[:vector_store_id]
                limit    = [params[:limit].to_i.then { |v| v.positive? ? v : 20 }, 100].min
                filter   = params[:filter]

                ds = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files]
                                                      .where(vector_store_id: store_id)
                                                      .order(::Sequel.desc(:created_at))
                                                      .limit(limit)
                ds = ds.where(status: filter) if filter

                rows = ds.all
                log.debug("[llm][api][vector_stores][files] action=list store_id=#{store_id} count=#{rows.size}")

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
                handle_exception(e, level: :error, operation: 'llm.api.vector_stores.files.list')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # GET /v1/vector_stores/:vector_store_id/files/:file_id — retrieve single file record
              get '/files/:vsf_id' do
                require_llm!
                require_data!
                Legion::LLM::VectorStore::Storage.ensure_tables!

                row = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files]
                                                       .where(id: params[:vsf_id], vector_store_id: params[:vector_store_id])
                                                       .first
                unless row
                  return openai_error("No vector_store.file found with id '#{params[:vsf_id]}'",
                                      type: 'invalid_request_error', code: 'not_found', status_code: 404)
                end

                log.debug("[llm][api][vector_stores][files] action=retrieve vsf_id=#{params[:vsf_id]}")

                content_type :json
                status 200
                Legion::JSON.dump(format_vsf(row))
              rescue StandardError => e
                handle_exception(e, level: :error, operation: 'llm.api.vector_stores.files.retrieve')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # POST /v1/vector_stores/:vector_store_id/files/:file_id — update attributes
              post '/files/:vsf_id' do
                require_llm!
                require_data!
                Legion::LLM::VectorStore::Storage.ensure_tables!
                body = parse_request_body

                row = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files]
                                                       .where(id: params[:vsf_id], vector_store_id: params[:vector_store_id])
                                                       .first
                unless row
                  return openai_error("No vector_store.file found with id '#{params[:vsf_id]}'",
                                      type: 'invalid_request_error', code: 'not_found', status_code: 404)
                end

                if body[:attributes].is_a?(Hash)
                  Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files]
                                                   .where(id: params[:vsf_id])
                                                   .update(attributes_json: Legion::JSON.dump(body[:attributes]))
                end

                row = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files]
                                                       .where(id: params[:vsf_id])
                                                       .first

                log.debug("[llm][api][vector_stores][files] action=update vsf_id=#{params[:vsf_id]}")

                content_type :json
                status 200
                Legion::JSON.dump(format_vsf(row))
              rescue StandardError => e
                handle_exception(e, level: :error, operation: 'llm.api.vector_stores.files.update')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # DELETE /v1/vector_stores/:vector_store_id/files/:file_id — remove file and chunks
              delete '/files/:vsf_id' do
                require_llm!
                require_data!
                Legion::LLM::VectorStore::Storage.ensure_tables!

                row = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files]
                                                       .where(id: params[:vsf_id], vector_store_id: params[:vector_store_id])
                                                       .first
                unless row
                  return openai_error("No vector_store.file found with id '#{params[:vsf_id]}'",
                                      type: 'invalid_request_error', code: 'not_found', status_code: 404)
                end

                Legion::LLM::VectorStore::Storage.db[:llm_vector_store_chunks]
                                                 .where(vector_store_file_id: params[:vsf_id])
                                                 .delete
                Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files]
                                                 .where(id: params[:vsf_id])
                                                 .delete

                log.debug("[llm][api][vector_stores][files] action=delete vsf_id=#{params[:vsf_id]}")

                content_type :json
                status 200
                Legion::JSON.dump({ id: params[:vsf_id], object: 'vector_store.file.deleted', deleted: true })
              rescue StandardError => e
                handle_exception(e, level: :error, operation: 'llm.api.vector_stores.files.delete')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # GET /v1/vector_stores/:vector_store_id/files/:file_id/content — raw chunks
              get '/files/:vsf_id/content' do
                require_llm!
                require_data!
                Legion::LLM::VectorStore::Storage.ensure_tables!

                row = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files]
                                                       .where(id: params[:vsf_id], vector_store_id: params[:vector_store_id])
                                                       .first
                unless row
                  return openai_error("No vector_store.file found with id '#{params[:vsf_id]}'",
                                      type: 'invalid_request_error', code: 'not_found', status_code: 404)
                end

                chunks = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_chunks]
                                                          .where(vector_store_file_id: params[:vsf_id])
                                                          .order(:chunk_index)
                                                          .all

                log.debug("[llm][api][vector_stores][files] action=content vsf_id=#{params[:vsf_id]} chunks=#{chunks.size}")

                content_type :json
                status 200
                Legion::JSON.dump({
                                    object:   'vector_store.file.content',
                                    file_id:  row[:file_id],
                                    data:     chunks.map { |c| { type: 'text', text: c[:text].to_s, chunk_index: c[:chunk_index] } },
                                    has_more: false
                                  })
              rescue StandardError => e
                handle_exception(e, level: :error, operation: 'llm.api.vector_stores.files.content')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              def fetch_file_content(file_id)
                return nil unless Legion::LLM::VectorStore::Storage.data_available?
                return nil unless Legion::LLM::VectorStore::Storage.db.table_exists?(:llm_files)

                Legion::LLM::VectorStore::Storage.db[:llm_files].where(id: file_id).first&.dig(:content)
              rescue StandardError => e
                handle_exception(e, level: :warn, handled: true, operation: 'llm.api.vector_stores.files.fetch_content')
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
