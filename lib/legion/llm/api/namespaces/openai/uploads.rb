# frozen_string_literal: true

require 'securerandom'
require 'fileutils'
require 'legion/logging/helper'
require 'legion/llm/api/namespaces/helpers'
require_relative 'files'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Uploads
            extend Legion::Logging::Helper

            UPLOAD_STORE = {} # rubocop:disable Style/MutableConstant
            UPLOAD_MUTEX = Mutex.new
            UPLOAD_TTL   = 3600 # 1 hour

            def self.registered(app) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
              log.debug('[llm][api][namespaces][openai][uploads] registering routes')

              # POST /v1/uploads
              app.post '/v1/uploads' do
                require_llm!
                body = parse_request_body
                validate_required!(body, :filename, :purpose, :bytes)

                upload_id = "upload_#{SecureRandom.hex(16)}"
                now       = Time.now

                entry = {
                  id:         upload_id,
                  object:     'upload',
                  filename:   body[:filename].to_s,
                  purpose:    body[:purpose].to_s,
                  bytes:      body[:bytes].to_i,
                  created_at: now,
                  expires_at: now + UPLOAD_TTL,
                  status:     'pending',
                  parts:      [],
                  file_id:    nil
                }

                UPLOAD_MUTEX.synchronize { UPLOAD_STORE[upload_id] = entry }
                log.debug("[llm][api][openai][uploads] action=create upload_id=#{upload_id} filename=#{entry[:filename]}")

                content_type :json
                status 200
                Legion::JSON.dump(Uploads.serialize_upload(entry))
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.uploads.create')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # POST /v1/uploads/:id/cancel
              app.post '/v1/uploads/:id/cancel' do
                require_llm!
                upload_id = params[:id]
                entry     = UPLOAD_MUTEX.synchronize { UPLOAD_STORE[upload_id] }

                unless entry
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "Upload '#{upload_id}' not found.",
                                                    type: 'invalid_request_error', code: 'upload_not_found' } })
                end

                UPLOAD_MUTEX.synchronize { UPLOAD_STORE[upload_id][:status] = 'cancelled' }
                log.debug("[llm][api][openai][uploads] action=cancel upload_id=#{upload_id}")

                content_type :json
                status 200
                Legion::JSON.dump(Uploads.serialize_upload(UPLOAD_MUTEX.synchronize { UPLOAD_STORE[upload_id] }))
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.uploads.cancel')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              # POST /v1/uploads/:id/complete
              app.post '/v1/uploads/:id/complete' do # rubocop:disable Metrics/BlockLength
                require_llm!
                upload_id = params[:id]
                body      = parse_request_body
                part_ids  = body[:part_ids] || []

                entry = UPLOAD_MUTEX.synchronize { UPLOAD_STORE[upload_id] }

                unless entry
                  halt 404, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "Upload '#{upload_id}' not found.",
                                                    type: 'invalid_request_error', code: 'upload_not_found' } })
                end

                unless entry[:status] == 'pending'
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: "Upload '#{upload_id}' is already #{entry[:status]}.",
                                                    type: 'invalid_request_error', code: 'upload_already_completed' } })
                end

                ordered_parts = if part_ids.any?
                                  part_ids.filter_map { |pid| entry[:parts].find { |p| p[:id] == pid } }
                                else
                                  entry[:parts]
                                end

                assembled = ordered_parts.map { |p| p[:data] }.join

                file_id = "file-#{SecureRandom.hex(16)}"
                ::FileUtils.mkdir_p(Files.files_dir)
                ::File.binwrite(::File.join(Files.files_dir, file_id), assembled)

                file_entry = {
                  id:         file_id,
                  filename:   entry[:filename],
                  purpose:    entry[:purpose],
                  bytes:      assembled.bytesize,
                  created_at: Time.now,
                  status:     'uploaded'
                }

                Files::FILE_MUTEX.synchronize { Files::FILE_STORE[file_id] = file_entry }

                UPLOAD_MUTEX.synchronize do
                  UPLOAD_STORE[upload_id][:status]  = 'completed'
                  UPLOAD_STORE[upload_id][:file_id] = file_id
                end

                completed_entry = UPLOAD_MUTEX.synchronize { UPLOAD_STORE[upload_id] }
                log.debug("[llm][api][openai][uploads] action=complete upload_id=#{upload_id} file_id=#{file_id} bytes=#{assembled.bytesize}")

                content_type :json
                status 200
                Legion::JSON.dump(Uploads.serialize_upload(completed_entry).merge(file: Uploads.serialize_file(file_entry)))
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.uploads.complete')
                openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
              end

              log.debug('[llm][api][namespaces][openai][uploads] routes registered')
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.uploads.register')
            end

            def self.serialize_upload(entry)
              {
                id:         entry[:id],
                object:     'upload',
                filename:   entry[:filename],
                purpose:    entry[:purpose],
                bytes:      entry[:bytes],
                created_at: entry[:created_at]&.to_i,
                expires_at: entry[:expires_at]&.to_i,
                status:     entry[:status],
                file_id:    entry[:file_id]
              }.compact
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
