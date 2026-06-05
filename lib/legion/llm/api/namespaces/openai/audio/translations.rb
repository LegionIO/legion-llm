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
            module Translations
              extend Sinatra::Extension
              extend Legion::Logging::Helper

              SUPPORTED_RESPONSE_FORMATS = %w[json text srt verbose_json vtt].freeze
              private_constant :SUPPORTED_RESPONSE_FORMATS

              def self.capable_provider_available?
                instances = begin
                  Legion::LLM::Call::Registry.all_instances
                rescue StandardError => e
                  log.debug "[llm][api][openai][audio][translations] action=registry_fallback error=#{e.class} message=#{e.message}"
                  []
                end
                instances.any? do |entry|
                  caps = entry[:capabilities] || entry['capabilities'] || []
                  syms = caps.map(&:to_sym)
                  syms.include?(:audio_translation) || syms.include?(:audio_transcription) || syms.include?(:speech_to_text)
                end
              rescue StandardError => e
                log.warn("[llm][api][openai][audio][translations] action=capability_check error=#{e.message}")
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

              def self.extract_translation_text(pipeline_response)
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
                "1\n00:00:00,000 --> 00:00:30,000\n#{text}\n\n"
              end

              def self.format_vtt(text)
                "WEBVTT\n\n00:00:00.000 --> 00:00:30.000\n#{text}\n\n"
              end

              post '/translations' do
                require_llm!

                unless Translations.capable_provider_available?
                  halt 501, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({
                                           error: {
                                             message: 'No provider with audio_translation capability is configured. ' \
                                                      'Enable a provider extension that supports audio translation (e.g. lex-llm-openai).',
                                             type:    'capability_not_supported',
                                             code:    nil
                                           }
                                         })
                end

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

                prompt_hint = (params_data['prompt']          || params_data[:prompt]).to_s
                resp_fmt    = (params_data['response_format'] || params_data[:response_format] || 'json').to_s.downcase
                temperature = (params_data['temperature']     || params_data[:temperature]).to_f

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

                file_b64   = Translations.read_file_param(file)
                request_id = "trans_#{SecureRandom.hex(14)}"

                log.info(
                  "[llm][api][openai][audio][translations] action=accepted request_id=#{request_id} " \
                  "model=#{model} format=#{resp_fmt}"
                )

                effective_caller = build_server_caller(source: 'openai_audio', path: request.path, env: env)

                inference_request = Legion::LLM::Inference::Request.build(
                  id:       request_id,
                  messages: [{ role: 'user', content: prompt_hint.empty? ? 'Translate this audio to English.' : prompt_hint }],
                  routing:  { model: model.to_s },
                  caller:   effective_caller,
                  stream:   false,
                  cache:    { strategy: :none, cacheable: false },
                  meta:     {
                    task:            :audio_translation,
                    audio_b64:       file_b64,
                    target_language: 'en',
                    temperature:     temperature,
                    response_format: resp_fmt
                  }
                )

                pipeline_response = Legion::LLM::Inference::Executor.new(inference_request).call
                translation_text = Translations.extract_translation_text(pipeline_response)

                log.info(
                  "[llm][api][openai][audio][translations] action=complete request_id=#{request_id} " \
                  "chars=#{translation_text.length} format=#{resp_fmt}"
                )

                case resp_fmt
                when 'text'
                  content_type 'text/plain'
                  status 200
                  translation_text
                when 'srt'
                  content_type 'text/plain'
                  status 200
                  Translations.format_srt(translation_text)
                when 'vtt'
                  content_type 'text/plain'
                  status 200
                  Translations.format_vtt(translation_text)
                when 'verbose_json'
                  content_type :json
                  status 200
                  Legion::JSON.dump({
                                      task:     'translate',
                                      language: 'en',
                                      duration: 0.0,
                                      text:     translation_text,
                                      words:    [],
                                      segments: []
                                    })
                else # 'json'
                  content_type :json
                  status 200
                  Legion::JSON.dump({ text: translation_text })
                end
              rescue Legion::LLM::AuthError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.audio.translations.auth')
                halt 401, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: e.message, type: 'authentication_error', code: nil } })
              rescue Legion::LLM::RateLimitError => e
                handle_exception(e, level: :warn, handled: true, operation: 'llm.api.openai.audio.translations.rate_limit')
                halt 429, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: e.message, type: 'rate_limit_error', code: nil } })
              rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.audio.translations.provider')
                halt 502, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: e.message, type: 'server_error', code: nil } })
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.audio.translations')
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
