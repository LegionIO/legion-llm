# frozen_string_literal: true

require 'securerandom'
require 'base64'
require 'sinatra/base'
require 'sinatra/extension'
require 'legion/logging/helper'
require 'legion/llm/inference/request'
require 'legion/llm/inference/executor'
require 'legion/llm/call/registry'

module Legion
  module LLM
    module API
      module Namespaces
        module OpenAI
          module Audio
            module Transcriptions
              extend Sinatra::Extension
              extend Legion::Logging::Helper

              SUPPORTED_RESPONSE_FORMATS = %w[json text srt verbose_json vtt].freeze
              private_constant :SUPPORTED_RESPONSE_FORMATS

              def self.capable_provider_available?
                instances = begin
                  Legion::LLM::Call::Registry.all_instances
                rescue StandardError => e
                  log.debug "[llm][api][openai][audio][transcriptions] action=registry_fallback error=#{e.class} message=#{e.message}"
                  []
                end
                instances.any? do |entry|
                  caps = entry[:capabilities] || entry['capabilities'] || []
                  syms = caps.map(&:to_sym)
                  syms.include?(:audio_transcription) || syms.include?(:speech_to_text)
                end
              rescue StandardError => e
                log.warn("[llm][api][openai][audio][transcriptions] action=capability_check error=#{e.message}")
                false
              end

              def self.read_file_param(file_param)
                return '' if file_param.nil? || file_param.to_s.empty?

                if file_param.is_a?(Hash)
                  tf = file_param[:tempfile] || file_param['tempfile']
                  return Base64.strict_encode64(tf.read) if tf.respond_to?(:read)
                end

                file_param.to_s
              end

              def self.extract_transcription_text(pipeline_response)
                raw_msg = pipeline_response.message
                case raw_msg
                when Hash
                  msg = raw_msg.respond_to?(:transform_keys) ? raw_msg.transform_keys(&:to_sym) : raw_msg
                  (msg[:content] || msg[:text] || '').to_s
                when String
                  raw_msg
                else
                  raw_msg.respond_to?(:content) ? raw_msg.content.to_s : raw_msg.to_s
                end
              end

              def self.format_srt(text)
                # Emit a minimal single-segment SRT from a plain transcription string
                "1\n00:00:00,000 --> 00:00:30,000\n#{text}\n\n"
              end

              def self.format_vtt(text)
                "WEBVTT\n\n00:00:00.000 --> 00:00:30.000\n#{text}\n\n"
              end

              post '/transcriptions' do
                require_llm!

                unless Transcriptions.capable_provider_available?
                  halt 501, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({
                                           error: {
                                             message: 'No provider with audio_transcription capability is configured. ' \
                                                      'Enable a provider extension that supports audio transcription (e.g. lex-llm-openai).',
                                             type:    'capability_not_supported',
                                             code:    nil
                                           }
                                         })
                end

                # Audio endpoints use multipart/form-data — params come from request.params
                params_data = request.params
                model = params_data['model'] || params_data[:model]
                file  = params_data['file']  || params_data[:file]

                if model.nil? || model.to_s.empty?
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: 'model is required', type: 'invalid_request_error', code: nil } })
                end

                if file.nil? || (file.is_a?(String) && file.empty?)
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: 'file is required', type: 'invalid_request_error', code: nil } })
                end

                language    = (params_data['language']          || params_data[:language]).to_s
                prompt_hint = (params_data['prompt']            || params_data[:prompt]).to_s
                resp_fmt    = (params_data['response_format']   || params_data[:response_format] || 'json').to_s.downcase
                temperature = (params_data['temperature']       || params_data[:temperature]).to_f
                granularity = params_data['timestamp_granularities'] || params_data[:timestamp_granularities]

                unless SUPPORTED_RESPONSE_FORMATS.include?(resp_fmt)
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({
                                           error: {
                                             message: "response_format must be one of: #{SUPPORTED_RESPONSE_FORMATS.join(', ')}",
                                             type:    'invalid_request_error',
                                             code:    nil
                                           }
                                         })
                end

                file_b64   = Transcriptions.read_file_param(file)
                request_id = "trans_#{SecureRandom.hex(14)}"

                log.info(
                  "[llm][api][openai][audio][transcriptions] action=accepted request_id=#{request_id} " \
                  "model=#{model} language=#{language.empty? ? 'auto' : language} format=#{resp_fmt}"
                )

                effective_caller = build_server_caller(source: 'openai_audio', path: request.path, env: env)

                inference_request = Legion::LLM::Inference::Request.build(
                  id:       request_id,
                  messages: [{ role: 'user', content: prompt_hint.empty? ? 'Transcribe this audio.' : prompt_hint }],
                  routing:  { model: model.to_s },
                  caller:   effective_caller,
                  stream:   false,
                  cache:    { strategy: :none, cacheable: false },
                  meta:     {
                    task:                    :audio_transcription,
                    audio_b64:               file_b64,
                    language:                language.empty? ? nil : language,
                    temperature:             temperature,
                    timestamp_granularities: granularity,
                    response_format:         resp_fmt
                  }.compact
                )

                pipeline_response = Legion::LLM::Inference::Executor.new(inference_request).call
                transcription_text = Transcriptions.extract_transcription_text(pipeline_response)

                log.info(
                  "[llm][api][openai][audio][transcriptions] action=complete request_id=#{request_id} " \
                  "chars=#{transcription_text.length} format=#{resp_fmt}"
                )

                case resp_fmt
                when 'text'
                  content_type 'text/plain'
                  status 200
                  transcription_text
                when 'srt'
                  content_type 'text/plain'
                  status 200
                  Transcriptions.format_srt(transcription_text)
                when 'vtt'
                  content_type 'text/plain'
                  status 200
                  Transcriptions.format_vtt(transcription_text)
                when 'verbose_json'
                  content_type :json
                  status 200
                  Legion::JSON.dump({
                                      task:     'transcribe',
                                      language: language.empty? ? 'en' : language,
                                      duration: 0.0,
                                      text:     transcription_text,
                                      words:    [],
                                      segments: []
                                    })
                else # 'json'
                  content_type :json
                  status 200
                  Legion::JSON.dump({ text: transcription_text })
                end
              rescue Legion::LLM::AuthError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.audio.transcriptions.auth')
                halt 401, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: e.message, type: 'authentication_error', code: nil } })
              rescue Legion::LLM::RateLimitError => e
                handle_exception(e, level: :warn, handled: true, operation: 'llm.api.openai.audio.transcriptions.rate_limit')
                halt 429, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: e.message, type: 'rate_limit_error', code: nil } })
              rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.audio.transcriptions.provider')
                halt 502, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: e.message, type: 'server_error', code: nil } })
              rescue Legion::LLM::Errors::RoutingRejected => e
                translate_routing_rejected(e, dialect: :openai, operation: 'llm.api.openai.audio.transcriptions.routing_rejected')
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.audio.transcriptions')
                halt 500, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: e.message, type: 'server_error', code: nil } })
              end
            end
          end
        end
      end
    end
  end
end
