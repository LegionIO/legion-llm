# frozen_string_literal: true

require 'securerandom'
require 'fileutils'
require 'concurrent'
require 'sinatra/base'
require 'sinatra/extension'
require 'sinatra/namespace'
require 'legion/logging/helper'

module Legion
  module LLM
    module API
      module Namespaces
        module Anthropic
          module Files
            extend Sinatra::Extension
            extend Legion::Logging::Helper

            # POST /v1/files — upload a file (multipart/form-data)
            post '' do
              require_llm!

              upload = params[:file]
              purpose = params[:purpose].to_s.strip

              if upload.nil?
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ type: 'error', error: { type: 'invalid_request_error', message: "missing required field: 'file'" } })
              end

              if purpose.empty?
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ type: 'error', error: { type: 'invalid_request_error', message: "missing required field: 'purpose'" } })
              end

              file_id   = "file_#{SecureRandom.hex(12)}"
              filename  = extract_filename(upload)
              mime_type = extract_mime_type(upload)
              content   = read_upload(upload)
              now       = Time.now.utc.iso8601

              log.debug("[llm][api][anthropic][files] action=upload file_id=#{file_id} filename=#{filename} purpose=#{purpose} size=#{content.bytesize}")

              persist_file(file_id: file_id, content: content)

              meta = {
                id:         file_id,
                type:       'file',
                filename:   filename,
                purpose:    purpose,
                size:       content.bytesize,
                created_at: now,
                mime_type:  mime_type
              }

              store_metadata(file_id, meta)

              content_type :json
              status 200
              Legion::JSON.dump(meta)
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.files.upload')
              anthropic_error('api_error', e.message, status_code: 500)
            end

            # GET /v1/files — list files with pagination
            get '' do
              require_llm!

              limit     = params[:limit].to_i.clamp(1, 100)
              limit     = 20 if params[:limit].nil? || params[:limit].to_s.strip.empty?
              purpose   = params[:purpose].to_s.strip
              before_id = params[:before_id].to_s.strip
              after_id  = params[:after_id].to_s.strip

              all = list_all_metadata

              all = all.select { |m| m[:purpose] == purpose } unless purpose.empty?

              all = all.sort_by { |m| m[:created_at] }.reverse

              all = apply_cursor(all, before_id: before_id.empty? ? nil : before_id, after_id: after_id.empty? ? nil : after_id)
              page      = all.first(limit)
              has_more  = all.size > limit

              log.debug("[llm][api][anthropic][files] action=list count=#{page.size} purpose=#{purpose.empty? ? 'all' : purpose}")

              content_type :json
              Legion::JSON.dump(
                {
                  data:     page,
                  has_more: has_more,
                  first_id: page.first&.dig(:id),
                  last_id:  page.last&.dig(:id)
                }
              )
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.files.list')
              anthropic_error('api_error', e.message, status_code: 500)
            end

            # GET /v1/files/:id — retrieve file metadata
            get '/:id' do
              require_llm!

              meta = load_metadata(params[:id])
              unless meta
                halt 404, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ type: 'error', error: { type: 'not_found_error', message: "File '#{params[:id]}' not found" } })
              end

              log.debug("[llm][api][anthropic][files] action=get file_id=#{params[:id]}")

              content_type :json
              Legion::JSON.dump(meta)
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.files.get')
              anthropic_error('api_error', e.message, status_code: 500)
            end

            # GET /v1/files/:id/content — download raw file bytes
            get '/:id/content' do
              require_llm!

              meta = load_metadata(params[:id])
              unless meta
                halt 404, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ type: 'error', error: { type: 'not_found_error', message: "File '#{params[:id]}' not found" } })
              end

              content = read_file_content(params[:id])
              unless content
                halt 404, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ type: 'error', error: { type: 'not_found_error', message: "File content for '#{params[:id]}' not found" } })
              end

              log.debug("[llm][api][anthropic][files] action=download file_id=#{params[:id]} size=#{content.bytesize}")

              content_type(meta[:mime_type] || 'application/octet-stream')
              headers 'Content-Disposition' => "attachment; filename=\"#{meta[:filename]}\""
              content
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.files.content')
              anthropic_error('api_error', e.message, status_code: 500)
            end

            # DELETE /v1/files/:id — delete file and metadata
            delete '/:id' do
              require_llm!

              meta = load_metadata(params[:id])
              unless meta
                halt 404, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ type: 'error', error: { type: 'not_found_error', message: "File '#{params[:id]}' not found" } })
              end

              delete_file(params[:id])
              delete_metadata(params[:id])

              log.debug("[llm][api][anthropic][files] action=delete file_id=#{params[:id]}")

              content_type :json
              Legion::JSON.dump({ id: params[:id], type: 'file', deleted: true })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.ns.anthropic.files.delete')
              anthropic_error('api_error', e.message, status_code: 500)
            end

            # rubocop:disable Metrics/BlockLength
            helpers do
              # ── Filename / MIME extraction ──────────────────────────────────

              def extract_filename(upload)
                return 'upload' unless upload.respond_to?(:original_filename) || upload.is_a?(Hash)

                name = upload.respond_to?(:original_filename) ? upload.original_filename : upload[:filename]
                name.to_s.empty? ? 'upload' : ::File.basename(name.to_s)
              end

              def extract_mime_type(upload)
                type = if upload.respond_to?(:content_type)
                         upload.content_type
                       elsif upload.is_a?(Hash)
                         upload[:type]
                       end
                type.to_s.empty? ? 'application/octet-stream' : type.to_s
              end

              def read_upload(upload)
                io = upload.respond_to?(:tempfile) ? upload.tempfile : upload[:tempfile]
                io = upload if io.nil? && upload.respond_to?(:read)
                raise Legion::LLM::LLMError, 'cannot read upload — no IO object' unless io.respond_to?(:read)

                io.rewind if io.respond_to?(:rewind)
                io.read
              end

              # ── Storage directory ───────────────────────────────────────────

              def files_storage_path
                configured = begin
                  Legion::Settings.dig(:llm, :files, :storage_path)
                rescue StandardError => e
                  log.debug "[llm][api][anthropic][files] action=files_storage_path_fallback error=#{e.class} message=#{e.message}"
                  nil
                end
                base = configured.to_s.empty? ? ::File.join(Dir.home, '.legionio', 'data', 'files') : configured
                ::FileUtils.mkdir_p(base)
                base
              end

              def file_content_path(file_id)
                ::File.join(files_storage_path, file_id)
              end

              # ── Content I/O ─────────────────────────────────────────────────

              def persist_file(file_id:, content:)
                path = file_content_path(file_id)
                ::File.binwrite(path, content)
              rescue StandardError => e
                handle_exception(e, level: :error, handled: true, operation: "llm.ns.anthropic.files.persist.#{file_id}")
                raise
              end

              def read_file_content(file_id)
                path = file_content_path(file_id)
                return nil unless ::File.exist?(path)

                ::File.binread(path)
              rescue StandardError => e
                handle_exception(e, level: :warn, handled: true, operation: "llm.ns.anthropic.files.read_content.#{file_id}")
                nil
              end

              def delete_file(file_id)
                path = file_content_path(file_id)
                ::FileUtils.rm_f(path)
              rescue StandardError => e
                handle_exception(e, level: :warn, handled: true, operation: "llm.ns.anthropic.files.delete_file.#{file_id}")
              end

              # ── Metadata store (in-memory fallback; Legion::Data when available) ──
              # MEDIUM #34: @metadata_store is per-request in Sinatra — use module-level accessor instead.
              # Concurrent::Map provides thread-safe reads/writes without explicit locking.

              def store_metadata(file_id, meta)
                Files.metadata_store[file_id] = meta
              end

              def load_metadata(file_id)
                Files.metadata_store[file_id]
              end

              def delete_metadata(file_id)
                Files.metadata_store.delete(file_id)
              end

              def list_all_metadata
                Files.metadata_store.values.dup
              end

              # ── Cursor-based pagination ─────────────────────────────────────
              # MEDIUM #38: List is sorted newest-first (index 0 = newest, index n = oldest).
              # - after_id: return items NEWER than the cursor (lower indexes) → sorted_list[0...idx]
              # - before_id: return items OLDER than the cursor (higher indexes) → sorted_list[(idx+1)..]

              def apply_cursor(sorted_list, before_id:, after_id:)
                if after_id
                  idx = sorted_list.index { |m| m[:id] == after_id }
                  return sorted_list unless idx

                  # Items newer than after_id are at lower indexes (before it in newest-first list)

                  return idx.positive? ? sorted_list[0...idx] : []
                end

                if before_id
                  idx = sorted_list.index { |m| m[:id] == before_id }
                  # Items older than before_id are at higher indexes (after it in newest-first list)
                  return idx ? sorted_list[(idx + 1)..] || [] : sorted_list
                end

                sorted_list
              end
            end
            # rubocop:enable Metrics/BlockLength

            # Thread-safe metadata store, re-initialized cleanly on each Sinatra::Extension register.
            def self.metadata_store
              @metadata_store ||= Concurrent::Map.new
            end

            # Reset for test isolation.
            def self.reset_metadata_store!
              @metadata_store = Concurrent::Map.new
            end
          end
        end
      end
    end
  end
end
