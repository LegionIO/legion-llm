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
            extend Sinatra::Extension
            extend Legion::Logging::Helper

            # POST /v1/vector_stores — create a new vector store
            post '' do
              require_llm!
              require_data!
              Legion::LLM::VectorStore::Storage.ensure_tables!
              body = parse_request_body

              id      = Legion::LLM::VectorStore::Storage.generate_id('vs')
              ts      = Legion::LLM::VectorStore::Storage.now_ts
              name    = body[:name].to_s
              meta    = body[:metadata].is_a?(Hash) ? Legion::JSON.dump(body[:metadata]) : '{}'
              expires = body.dig(:expires_after, :days)&.then { |d| ts + (d * 86_400) }

              Legion::LLM::VectorStore::Storage.db[:llm_vector_stores].insert(
                id:             id,
                name:           name,
                status:         'completed',
                metadata_json:  meta,
                usage_bytes:    0,
                expires_at:     expires,
                created_at:     ts,
                last_active_at: ts
              )

              log.debug("[llm][api][vector_stores] action=create id=#{id} name=#{name}")

              content_type :json
              status 200
              Legion::JSON.dump(format_store(Legion::LLM::VectorStore::Storage.db[:llm_vector_stores].where(id: id).first))
            rescue StandardError => e
              handle_exception(e, level: :error, operation: 'llm.api.vector_stores.create')
              openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
            end

            # GET /v1/vector_stores — list all stores
            get '' do
              require_llm!
              require_data!
              Legion::LLM::VectorStore::Storage.ensure_tables!

              limit = [params[:limit].to_i.then { |v| v.positive? ? v : 20 }, 100].min
              rows  = Legion::LLM::VectorStore::Storage.db[:llm_vector_stores]
                                                       .order(::Sequel.desc(:created_at))
                                                       .limit(limit)
                                                       .all

              log.debug("[llm][api][vector_stores] action=list count=#{rows.size}")

              content_type :json
              status 200
              Legion::JSON.dump({
                                  object:   'list',
                                  data:     rows.map { |r| format_store(r) },
                                  has_more: false,
                                  first_id: rows.first&.dig(:id),
                                  last_id:  rows.last&.dig(:id)
                                })
            rescue StandardError => e
              handle_exception(e, level: :error, operation: 'llm.api.vector_stores.list')
              openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
            end

            # GET /v1/vector_stores/:id — retrieve a store
            get '/:id' do
              require_llm!
              require_data!
              Legion::LLM::VectorStore::Storage.ensure_tables!

              row = Legion::LLM::VectorStore::Storage.db[:llm_vector_stores].where(id: params[:id]).first
              unless row
                return openai_error("No vector_store found with id '#{params[:id]}'",
                                    type: 'invalid_request_error', code: 'not_found', status_code: 404)
              end

              log.debug("[llm][api][vector_stores] action=retrieve id=#{params[:id]}")

              content_type :json
              status 200
              Legion::JSON.dump(format_store(row))
            rescue StandardError => e
              handle_exception(e, level: :error, operation: 'llm.api.vector_stores.retrieve')
              openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
            end

            # POST /v1/vector_stores/:id/search — semantic search over stored chunks
            # MUST be defined BEFORE post '/:id' so Sinatra matches the more specific /search path first
            post '/:id/search' do
              require_llm!
              require_data!
              Legion::LLM::VectorStore::Storage.ensure_tables!
              body = parse_request_body

              validate_required!(body, :query)

              row = Legion::LLM::VectorStore::Storage.db[:llm_vector_stores].where(id: params[:id]).first
              unless row
                return openai_error("No vector_store found with id '#{params[:id]}'",
                                    type: 'invalid_request_error', code: 'not_found', status_code: 404)
              end

              max_results = body[:max_num_results].to_i.then { |v| v.positive? ? [v, 50].min : 10 }
              filters     = body[:filters]

              embed_result = Legion::LLM::Call::Embeddings.generate(
                text: body[:query].to_s,
                task: :query
              )

              if embed_result[:vector].nil?
                return openai_error(
                  embed_result[:error] || 'Embedding generation failed',
                  type:        'server_error',
                  code:        'embedding_unavailable',
                  status_code: 503
                )
              end

              query_vector = embed_result[:vector]

              chunk_ds = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_chunks]
                                                          .where(vector_store_id: params[:id])
                                                          .select(:file_id, :vector_store_file_id, :chunk_index, :text, :embedding_json)
                                                          .limit(VectorStore::Storage::MAX_SCAN_CHUNKS)
              chunk_ds = chunk_ds.where(file_id: Array(filters[:file_ids])) if filters.is_a?(Hash) && filters[:file_ids]

              chunks = chunk_ds.all
              log.debug("[llm][api][vector_stores] action=search id=#{params[:id]} chunks=#{chunks.size}")

              scored = chunks.filter_map do |chunk|
                vec = Legion::JSON.load(chunk[:embedding_json] || '[]')
                next unless vec.is_a?(Array) && vec.size == query_vector.size

                score = Legion::LLM::VectorStore::Storage.cosine_similarity(query_vector, vec)
                {
                  file_id:    chunk[:file_id],
                  score:      score.round(6),
                  content:    [{ type: 'text', text: chunk[:text].to_s }],
                  attributes: {}
                }
              end

              results = scored.sort_by { |r| -r[:score] }.first(max_results)

              content_type :json
              status 200
              Legion::JSON.dump({
                                  object:       'vector_store.search_results',
                                  search_query: body[:query].to_s,
                                  data:         results,
                                  has_more:     false,
                                  next_page:    nil
                                })
            rescue StandardError => e
              handle_exception(e, level: :error, operation: 'llm.api.vector_stores.search')
              openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
            end
            # POST /v1/vector_stores/:id — update a store (name, metadata)
            # Defined AFTER post '/:id/search' so Sinatra selects the search route first
            post '/:id' do
              require_llm!
              require_data!
              Legion::LLM::VectorStore::Storage.ensure_tables!
              body = parse_request_body

              row = Legion::LLM::VectorStore::Storage.db[:llm_vector_stores].where(id: params[:id]).first
              unless row
                return openai_error("No vector_store found with id '#{params[:id]}'",
                                    type: 'invalid_request_error', code: 'not_found', status_code: 404)
              end

              updates = {}
              updates[:name]           = body[:name].to_s if body.key?(:name)
              updates[:metadata_json]  = Legion::JSON.dump(body[:metadata]) if body[:metadata].is_a?(Hash)
              updates[:last_active_at] = Legion::LLM::VectorStore::Storage.now_ts

              Legion::LLM::VectorStore::Storage.db[:llm_vector_stores].where(id: params[:id]).update(updates) if updates.any?

              log.debug("[llm][api][vector_stores] action=update id=#{params[:id]} fields=#{updates.keys.join(',')}")

              content_type :json
              status 200
              Legion::JSON.dump(format_store(Legion::LLM::VectorStore::Storage.db[:llm_vector_stores].where(id: params[:id]).first))
            rescue StandardError => e
              handle_exception(e, level: :error, operation: 'llm.api.vector_stores.update')
              openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
            end

            # DELETE /v1/vector_stores/:id — delete store and cascade
            delete '/:id' do
              require_llm!
              require_data!
              Legion::LLM::VectorStore::Storage.ensure_tables!

              row = Legion::LLM::VectorStore::Storage.db[:llm_vector_stores].where(id: params[:id]).first
              unless row
                return openai_error("No vector_store found with id '#{params[:id]}'",
                                    type: 'invalid_request_error', code: 'not_found', status_code: 404)
              end

              Legion::LLM::VectorStore::Storage.db[:llm_vector_store_chunks].where(vector_store_id: params[:id]).delete
              Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files].where(vector_store_id: params[:id]).delete
              Legion::LLM::VectorStore::Storage.db[:llm_vector_store_batches].where(vector_store_id: params[:id]).delete
              Legion::LLM::VectorStore::Storage.db[:llm_vector_stores].where(id: params[:id]).delete

              log.debug("[llm][api][vector_stores] action=delete id=#{params[:id]}")

              content_type :json
              status 200
              Legion::JSON.dump({ id: params[:id], object: 'vector_store.deleted', deleted: true })
            rescue StandardError => e
              handle_exception(e, level: :error, operation: 'llm.api.vector_stores.delete')
              openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
            end

            def format_store(row)
              return nil unless row

              meta = Legion::JSON.load(row[:metadata_json] || '{}')
              {
                id:             row[:id],
                object:         'vector_store',
                name:           row[:name].to_s,
                status:         row[:status].to_s,
                file_counts:    build_file_counts(row[:id]),
                usage_bytes:    row[:usage_bytes].to_i,
                created_at:     row[:created_at].to_i,
                last_active_at: row[:last_active_at].to_i,
                expires_at:     row[:expires_at],
                expires_after:  nil,
                metadata:       meta
              }
            end

            def build_file_counts(vector_store_id)
              return { in_progress: 0, completed: 0, failed: 0, cancelled: 0, total: 0 } \
                unless Legion::LLM::VectorStore::Storage.data_available?

              ds = Legion::LLM::VectorStore::Storage.db[:llm_vector_store_files].where(vector_store_id: vector_store_id)
              in_progress = ds.where(status: 'in_progress').count
              completed   = ds.where(status: 'completed').count
              failed      = ds.where(status: 'failed').count
              cancelled   = ds.where(status: 'cancelled').count
              {
                in_progress: in_progress,
                completed:   completed,
                failed:      failed,
                cancelled:   cancelled,
                total:       in_progress + completed + failed + cancelled
              }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'llm.api.vector_stores.file_counts')
              { in_progress: 0, completed: 0, failed: 0, cancelled: 0, total: 0 }
            end
          end
        end
      end
    end
  end
end
