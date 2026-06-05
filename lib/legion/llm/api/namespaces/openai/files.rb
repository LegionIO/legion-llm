# frozen_string_literal: true

require 'securerandom'
require 'fileutils'
require 'legion/logging/helper'
require 'legion/llm/api/namespaces/helpers'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Files
            extend Legion::Logging::Helper

            FILE_STORE = {} # rubocop:disable Style/MutableConstant
            FILE_MUTEX = Mutex.new

            CONTENT_TYPE_MAP = {
              '.jsonl' => 'application/jsonl',
              '.json'  => 'application/json',
              '.txt'   => 'text/plain',
              '.csv'   => 'text/csv',
              '.pdf'   => 'application/pdf'
            }.freeze

            def self.files_dir
              ::File.join(::Dir.home, '.legionio', 'data', 'files')
            end

            def self.registered(app) # rubocop:disable Metrics/AbcSize
              log.debug('[llm][api][namespaces][openai][files] registering routes')

              # POST /v1/files  (multipart/form-data)
              app.post '/v1/files' do
                require_llm!

                uploaded = params[:file]
                purpose  = params[:purpose]

                unless uploaded
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: 'file is required',
                                                    type: 'invalid_request_error', code: 'missing_file' } })
                end

                unless purpose
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: 'purpose is required',
                                                    type: 'invalid_request_error', code: 'missing_purpose' } })
                end

                file_id  = "file-#{SecureRandom.hex(16)}"
                filename = begin
                  uploaded[:filename] || uploaded.original_filename
                rescue StandardError => e
                  log.debug "[llm][api][openai][files] action=filename_fallback error=#{e.class} message=#{e.message}"
                  'upload.bin'
                end
                data = begin
                  uploaded[:tempfile]&.read || uploaded.read
                rescue StandardError => e
                  log.debug "[llm][api][openai][files] action=file_read_fallback error=#{e.class} message=#{e.message}"
                  ''
                end

                ::FileUtils.mkdir_p(Files.files_dir)
                dest = ::File.join(Files.files_dir, file_id)
                ::File.binwrite(dest, data)

                entry = {
                  id:         file_id,
                  filename:   filename.to_s,
                  purpose:    purpose.to_s,
                  bytes:      data.bytesize,
                  created_at: Time.now,
                  status:     'uploaded'
                }

                FILE_MUTEX.synchronize { FILE_STORE[file_id] = entry }
                log.debug("[llm][api][openai][files] action=upload file_id=#{file_id} filename=#{filename} bytes=#{data.bytesize}")

                content_type :json
                status 200
                Legion::JSON.dump(Files.serialize_file(entry))
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.files.upload')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # GET /v1/files (list)
              app.get '/v1/files' do
                require_llm!
                purpose = params[:purpose]
                limit   = params[:limit]&.to_i || 20
                after   = params[:after]

                entries = FILE_MUTEX.synchronize { FILE_STORE.values.dup }
                entries.select! { |f| f[:purpose] == purpose } if purpose
                entries.sort_by! { |f| -f[:created_at].to_i }

                if after
                  idx     = entries.index { |f| f[:id] == after }
                  entries = entries[(idx + 1)..] if idx
                end

                entries = entries.first(limit)
                log.debug("[llm][api][openai][files] action=list count=#{entries.size}")

                content_type :json
                status 200
                Legion::JSON.dump({
                                    object:   'list',
                                    data:     entries.map { |f| Files.serialize_file(f) },
                                    has_more: false
                                  })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.files.list')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # GET /v1/files/:id
              app.get '/v1/files/:id' do
                require_llm!
                file_id = params[:id]
                entry   = FILE_MUTEX.synchronize { FILE_STORE[file_id] }

                unless entry
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "File '#{file_id}' not found.",
                                                    type: 'invalid_request_error', code: 'file_not_found' } })
                end

                log.debug("[llm][api][openai][files] action=get file_id=#{file_id}")
                content_type :json
                status 200
                Legion::JSON.dump(Files.serialize_file(entry))
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.files.get')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # DELETE /v1/files/:id
              app.delete '/v1/files/:id' do
                require_llm!
                file_id = params[:id]
                entry   = FILE_MUTEX.synchronize { FILE_STORE[file_id] }

                unless entry
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "File '#{file_id}' not found.",
                                                    type: 'invalid_request_error', code: 'file_not_found' } })
                end

                disk_path = ::File.join(Files.files_dir, file_id)
                ::FileUtils.rm_f(disk_path)
                FILE_MUTEX.synchronize { FILE_STORE.delete(file_id) }

                log.debug("[llm][api][openai][files] action=delete file_id=#{file_id}")
                content_type :json
                status 200
                Legion::JSON.dump({ id: file_id, object: 'file', deleted: true })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.files.delete')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # GET /v1/files/:id/content
              app.get '/v1/files/:id/content' do
                require_llm!
                file_id = params[:id]
                entry   = FILE_MUTEX.synchronize { FILE_STORE[file_id] }

                unless entry
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "File '#{file_id}' not found.",
                                                    type: 'invalid_request_error', code: 'file_not_found' } })
                end

                disk_path = ::File.join(Files.files_dir, file_id)
                unless ::File.exist?(disk_path)
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "File content for '#{file_id}' is missing from disk.",
                                                    type: 'invalid_request_error', code: 'file_content_missing' } })
                end

                ext          = ::File.extname(entry[:filename].to_s).downcase
                content_mime = CONTENT_TYPE_MAP[ext] || 'application/octet-stream'
                raw          = ::File.binread(disk_path)

                log.debug("[llm][api][openai][files] action=content file_id=#{file_id} bytes=#{raw.bytesize}")
                content_type content_mime
                status 200
                raw
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.files.content')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              log.debug('[llm][api][namespaces][openai][files] routes registered')
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.files.register')
            end

            def self.serialize_file(entry)
              {
                id:         entry[:id],
                object:     'file',
                bytes:      entry[:bytes],
                created_at: entry[:created_at]&.to_i,
                filename:   entry[:filename],
                purpose:    entry[:purpose],
                status:     entry[:status]
              }
            end
          end
        end
      end
    end
  end
end
