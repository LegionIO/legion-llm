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
            module Speech
              extend Sinatra::Extension
              extend Legion::Logging::Helper

              VALID_VOICES = %w[alloy ash ballad coral echo fable nova onyx sage shimmer].freeze
              VALID_FORMATS = %w[mp3 opus aac flac wav pcm].freeze

              AUDIO_CONTENT_TYPES = {
                'mp3'  => 'audio/mpeg',
                'opus' => 'audio/opus',
                'aac'  => 'audio/aac',
                'flac' => 'audio/flac',
                'wav'  => 'audio/wav',
                'pcm'  => 'audio/pcm'
              }.freeze

              private_constant :VALID_VOICES, :VALID_FORMATS

              def self.capable_provider_available?
                instances = begin
                  Legion::LLM::Call::Registry.all_instances
                rescue StandardError => e
                  log.debug "[llm][api][openai][audio][speech] action=registry_fallback error=#{e.class} message=#{e.message}"
                  []
                end
                instances.any? do |entry|
                  caps = entry[:capabilities] || entry['capabilities'] || []
                  syms = caps.map(&:to_sym)
                  syms.include?(:text_to_speech) || syms.include?(:audio_speech) || syms.include?(:tts)
                end
              rescue StandardError => e
                log.warn("[llm][api][openai][audio][speech] action=capability_check error=#{e.message}")
                false
              end

              def self.extract_audio_bytes(pipeline_response, response_format:)
                _ = response_format # unused, retained for contract stability
                raw_msg = pipeline_response.message
                msg = raw_msg.respond_to?(:transform_keys) ? raw_msg.transform_keys(&:to_sym) : {}

                audio_binary = msg[:audio_binary]
                return audio_binary if audio_binary.is_a?(String) && !audio_binary.empty?

                audio_b64 = msg[:audio_b64]
                return Base64.strict_decode64(audio_b64) if audio_b64.is_a?(String) && !audio_b64.empty?

                # Fallback: provider returned text content
                content = msg[:content].to_s
                content.empty? ? '' : content.encode('BINARY', invalid: :replace, undef: :replace)
              end

              def self.resolve_audio_format(pipeline_response, requested_format:)
                raw_msg = pipeline_response.message
                msg = raw_msg.respond_to?(:transform_keys) ? raw_msg.transform_keys(&:to_sym) : {}
                returned_fmt = (msg[:audio_format] || msg[:format]).to_s.downcase
                VALID_FORMATS.include?(returned_fmt) ? returned_fmt : requested_format
              end

              post '/speech' do
                require_llm!

                unless Speech.capable_provider_available?
                  halt 501, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({
                                           error: {
                                             message: 'No provider with text_to_speech capability is configured. ' \
                                                      'Enable a provider extension that supports TTS (e.g. lex-llm-openai).',
                                             type:    'capability_not_supported',
                                             code:    nil
                                           }
                                         })
                end

                raw = request.body.read
                body = if raw.nil? || raw.empty?
                         {}
                       else
                         begin
                           Legion::JSON.load(raw)
                         rescue StandardError => e
                           log.debug "[llm][api][openai][audio][speech] action=parse_body_fallback error=#{e.class} message=#{e.message}"
                           {}
                         end
                       end

                model = body[:model] || body['model']
                input = body[:input] || body['input']
                voice = body[:voice] || body['voice']

                if model.nil? || model.to_s.empty?
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: 'model is required', type: 'invalid_request_error', code: nil } })
                end

                if input.nil? || input.to_s.empty?
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: 'input is required', type: 'invalid_request_error', code: nil } })
                end

                if voice.nil? || voice.to_s.empty?
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({ error: { message: 'voice is required', type: 'invalid_request_error', code: nil } })
                end

                voice_str = voice.to_s.downcase
                unless VALID_VOICES.include?(voice_str)
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({
                                           error: {
                                             message: "voice must be one of: #{VALID_VOICES.join(', ')}",
                                             type:    'invalid_request_error',
                                             code:    nil
                                           }
                                         })
                end

                resp_fmt = (body[:response_format] || body['response_format'] || 'mp3').to_s.downcase
                unless VALID_FORMATS.include?(resp_fmt)
                  halt 400, { 'Content-Type' => 'application/json' },
                       Legion::JSON.dump({
                                           error: {
                                             message: "response_format must be one of: #{VALID_FORMATS.join(', ')}",
                                             type:    'invalid_request_error',
                                             code:    nil
                                           }
                                         })
                end

                speed      = (body[:speed] || body['speed'] || 1.0).to_f.clamp(0.25, 4.0)
                request_id = "speech_#{SecureRandom.hex(14)}"

                log.info(
                  "[llm][api][openai][audio][speech] action=accepted request_id=#{request_id} " \
                  "model=#{model} voice=#{voice_str} format=#{resp_fmt} speed=#{speed} " \
                  "input_length=#{input.to_s.length}"
                )

                effective_caller = build_server_caller(source: 'openai_audio', path: request.path, env: env)

                inference_request = Legion::LLM::Inference::Request.build(
                  id:       request_id,
                  messages: [{ role: 'user', content: input.to_s }],
                  routing:  { model: model.to_s },
                  caller:   effective_caller,
                  stream:   false,
                  cache:    { strategy: :none, cacheable: false },
                  meta:     {
                    task:            :text_to_speech,
                    voice:           voice_str,
                    speed:           speed,
                    response_format: resp_fmt
                  }
                )

                pipeline_response = Legion::LLM::Inference::Executor.new(inference_request).call
                audio_bytes = Speech.extract_audio_bytes(pipeline_response, response_format: resp_fmt)
                effective_fmt = Speech.resolve_audio_format(pipeline_response, requested_format: resp_fmt)
                mime_type = AUDIO_CONTENT_TYPES.fetch(effective_fmt, 'audio/mpeg')

                log.info(
                  "[llm][api][openai][audio][speech] action=complete request_id=#{request_id} " \
                  "format=#{effective_fmt} bytes=#{audio_bytes.bytesize}"
                )

                content_type mime_type
                status 200
                audio_bytes
              rescue Legion::LLM::AuthError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.audio.speech.auth')
                halt 401, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: e.message, type: 'authentication_error', code: nil } })
              rescue Legion::LLM::RateLimitError => e
                handle_exception(e, level: :warn, handled: true, operation: 'llm.api.openai.audio.speech.rate_limit')
                halt 429, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: e.message, type: 'rate_limit_error', code: nil } })
              rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
                handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.audio.speech.provider')
                halt 502, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: e.message, type: 'server_error', code: nil } })
              rescue Legion::LLM::Errors::RoutingRejected => e
                translate_routing_rejected(e, dialect: :openai, operation: 'llm.api.openai.audio.speech.routing_rejected')
              rescue StandardError => e
                handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.audio.speech')
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
