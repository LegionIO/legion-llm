# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'
require 'legion/llm/api/namespaces/helpers'
require_relative '../uploads'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Uploads
            module Parts
              extend Legion::Logging::Helper

              MAX_PART_SIZE_BYTES = (ENV.fetch('LEGION_UPLOAD_MAX_PART_MB', '64').to_i * 1024 * 1024)
              MAX_TOTAL_UPLOAD_BYTES = (ENV.fetch('LEGION_UPLOAD_MAX_TOTAL_MB', '512').to_i * 1024 * 1024)

              def self.registered(app)
                log.debug('[llm][api][namespaces][openai][parts] registering routes')

                # POST /v1/uploads/:id/parts
                app.post '/v1/uploads/:id/parts' do # rubocop:disable Metrics/BlockLength
                  require_llm!
                  upload_id = params[:id]
                  entry     = Uploads::UPLOAD_MUTEX.synchronize { Uploads::UPLOAD_STORE[upload_id] }

                  unless entry
                    halt 404, { 'Content-Type' => 'application/json' },
                         Legion::JSON.dump({ error: { message: "Upload '#{upload_id}' not found.",
                                                      type: 'invalid_request_error', code: 'upload_not_found' } })
                  end

                  unless entry[:status] == 'pending'
                    halt 400, { 'Content-Type' => 'application/json' },
                         Legion::JSON.dump({ error: { message: "Upload '#{upload_id}' is #{entry[:status]}, not pending.",
                                                      type: 'invalid_request_error', code: 'upload_not_pending' } })
                  end

                  raw_data = Parts.extract_part_data(request, params)

                  if raw_data.bytesize > MAX_PART_SIZE_BYTES
                    halt 413, { 'Content-Type' => 'application/json' },
                         Legion::JSON.dump({ error: { message: "Part size #{raw_data.bytesize} bytes exceeds maximum #{MAX_PART_SIZE_BYTES} bytes.",
                                                      type: 'invalid_request_error', code: 'part_too_large' } })
                  end

                  existing_total = Uploads::UPLOAD_MUTEX.synchronize do
                    Uploads::UPLOAD_STORE[upload_id][:parts].sum { |p| p[:data].bytesize }
                  end

                  if existing_total + raw_data.bytesize > MAX_TOTAL_UPLOAD_BYTES
                    halt 413, { 'Content-Type' => 'application/json' },
                         Legion::JSON.dump({ error: { message: "Total upload size would exceed #{MAX_TOTAL_UPLOAD_BYTES / 1024 / 1024}MB limit.",
                                                      type: 'invalid_request_error', code: 'upload_too_large' } })
                  end

                  part_id = "part_#{SecureRandom.hex(16)}"
                  part    = { id: part_id, data: raw_data, created_at: Time.now }

                  Uploads::UPLOAD_MUTEX.synchronize { Uploads::UPLOAD_STORE[upload_id][:parts] << part }
                  log.debug("[llm][api][openai][parts] action=create upload_id=#{upload_id} part_id=#{part_id} bytes=#{raw_data.bytesize}")

                  content_type :json
                  status 200
                  Legion::JSON.dump({
                                      id:         part_id,
                                      object:     'upload.part',
                                      upload_id:  upload_id,
                                      created_at: part[:created_at].to_i
                                    })
                rescue StandardError => e
                  handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.parts.create')
                  openai_error(e.message, type: 'server_error', code: 'internal_error', status_code: 500)
                end

                log.debug('[llm][api][namespaces][openai][parts] routes registered')
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.parts.register')
              end

              def self.extract_part_data(req, prms)
                if prms[:data]
                  d = prms[:data]
                  tf = d.respond_to?(:read) ? d : d[:tempfile]
                  return tf.read if tf.respond_to?(:read)
                end

                req.body.rewind
                raw = req.body.read
                return raw unless raw.nil? || raw.empty?

                ''
              end
            end
          end
        end
      end
    end
  end
end
