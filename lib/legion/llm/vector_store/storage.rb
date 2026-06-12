# frozen_string_literal: true

require 'securerandom'
require 'legion/json'
require 'legion/logging/helper'

module Legion
  module LLM
    module VectorStore
      module Storage
        extend Legion::Logging::Helper

        module_function

        def data_available?
          return false unless defined?(Legion::Data)
          return false unless Legion::Data.respond_to?(:connected?) && Legion::Data.connected?

          true
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.vector_store.dataAvailable?')
          false
        end

        def db
          Legion::Data.db
        end

        def ensure_tables!
          return unless data_available?

          db.create_table?(:llm_vector_stores) do
            String   :id, primary_key: true
            String   :name
            String   :status, default: 'completed'
            String   :metadata_json, default: '{}'
            Integer  :usage_bytes, default: 0
            Integer  :expires_at
            Integer  :created_at
            Integer  :last_active_at
          end

          db.create_table?(:llm_vector_store_files) do
            String   :id, primary_key: true
            String   :vector_store_id
            String   :file_id
            String   :status, default: 'in_progress'
            Integer  :usage_bytes, default: 0
            String   :chunking_strategy_json, default: '{"type":"auto"}'
            String   :attributes_json, default: '{}'
            String   :last_error_json
            Integer  :created_at
          end
          safe_add_index(:llm_vector_store_files, :vector_store_id, name: :idx_vsf_vector_store_id)
          safe_add_index(:llm_vector_store_files, :file_id, name: :idx_vsf_file_id)

          db.create_table?(:llm_vector_store_chunks) do
            String   :id, primary_key: true
            String   :vector_store_id
            String   :vector_store_file_id
            String   :file_id
            Integer  :chunk_index
            String   :text, text: true
            String   :embedding_json, text: true
            Integer  :created_at
          end
          safe_add_index(:llm_vector_store_chunks, :vector_store_id, name: :idx_vsc_vector_store_id)
          safe_add_index(:llm_vector_store_chunks, :vector_store_file_id, name: :idx_vsc_vector_store_file_id)

          db.create_table?(:llm_vector_store_batches) do
            String   :id, primary_key: true
            String   :vector_store_id
            String   :status, default: 'in_progress'
            String   :file_ids_json, default: '[]'
            String   :file_counts_json, default: '{"in_progress":0,"completed":0,"failed":0,"cancelled":0,"total":0}'
            Integer  :created_at
            index    :vector_store_id
          end

          log.debug('[llm][vector_store] action=ensure_tables tables=created')
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'llm.vector_store.ensure_tables')
          raise
        end

        MAX_SCAN_CHUNKS = 10_000

        def generate_id(prefix)
          "#{prefix}_#{SecureRandom.hex(10)}"
        end

        def now_ts
          Time.now.to_i
        end

        def cosine_similarity(vec_a, vec_b)
          return 0.0 if vec_a.nil? || vec_b.nil?
          return 0.0 unless vec_a.is_a?(Array) && vec_b.is_a?(Array)
          return 0.0 unless vec_a.size == vec_b.size && vec_a.size.positive?

          dot   = vec_a.zip(vec_b).sum { |x, y| x.to_f * y.to_f }
          mag_a = Math.sqrt(vec_a.sum { |x| x.to_f**2 })
          mag_b = Math.sqrt(vec_b.sum { |x| x.to_f**2 })
          denom = mag_a * mag_b
          return 0.0 if denom.zero?

          (dot / denom).clamp(-1.0, 1.0)
        end

        def chunk_text(text, max_chars: 512)
          paragraphs = text.split(/\n\n+/).map(&:strip).reject(&:empty?)
          chunks     = []
          current    = +''

          paragraphs.each do |para|
            if current.empty?
              current << para
            elsif (current.length + para.length + 2) <= max_chars
              current << "\n\n" << para
            else
              chunks << current.dup
              current.clear
              current << para
            end
          end

          chunks << current unless current.empty?
          chunks.empty? ? [text[0, max_chars]] : chunks
        end

        def safe_add_index(table, column, name:)
          db.add_index(table, column, name: name)
        rescue StandardError => e
          log.debug "[llm][vector_store][storage] action=safe_add_index_skipped table=#{table} index=#{name} error=#{e.class} message=#{e.message}"
        end
      end
    end
  end
end
