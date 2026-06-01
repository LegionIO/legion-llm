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
          module Images
            extend Sinatra::Extension
            extend Legion::Logging::Helper

            # ─── helpers ─────────────────────────────────────────────────────

            def self.capable_provider_available?(capability)
              instances = begin
                Legion::LLM::Call::Registry.all_instances
              rescue StandardError => e
                log.debug "[llm][api][openai][images] action=registry_fallback capability=#{capability} error=#{e.class} message=#{e.message}"
                []
              end
              instances.any? do |entry|
                caps = entry[:capabilities] || entry['capabilities'] || []
                caps.include?(capability) || caps.map(&:to_sym).include?(capability)
              end
            rescue StandardError => e
              Legion::Logging::Helper.log.warn(
                "[llm][api][openai][images] action=capability_check capability=#{capability} error=#{e.message}"
              )
              false
            end

            def self.extract_images_from_response(pipeline_response)
              raw_msg = pipeline_response.message
              msg = raw_msg.respond_to?(:transform_keys) ? raw_msg.transform_keys(&:to_sym) : {}
              images = msg[:images]
              return images if images.is_a?(Array) && !images.empty?

              # Fallback: wrap content string as b64_json if it looks like base64
              content = msg[:content].to_s
              return [] if content.empty?

              [{ b64_json: content }]
            end

            def self.format_images_response(pipeline_response, response_format: 'b64_json')
              images = extract_images_from_response(pipeline_response)
              data = images.map do |img|
                i = img.respond_to?(:transform_keys) ? img.transform_keys(&:to_sym) : img
                if i[:b64_json]
                  { b64_json: i[:b64_json] }
                elsif i[:url] && response_format == 'url'
                  { url: i[:url] }
                else
                  { b64_json: '' }
                end
              end

              { created: Time.now.to_i, data: data }
            end

            def self.parse_media_body(request)
              ct = request.content_type.to_s.downcase
              if ct.include?('multipart/form-data') || ct.include?('application/x-www-form-urlencoded')
                request.params.transform_keys(&:to_sym)
              else
                raw = request.body.read
                return {} if raw.nil? || raw.empty?

                Legion::JSON.load(raw)
              end
            rescue StandardError => e
              log.debug "[llm][api][openai][images] action=parse_media_body_fallback error=#{e.class} message=#{e.message}"
              {}
            end

            def self.normalize_image_param(image_param)
              # Rack multipart uploads arrive as hashes: { filename:, type:, tempfile: }
              if image_param.is_a?(Hash)
                tf = image_param[:tempfile] || image_param['tempfile']
                return Base64.strict_encode64(tf.read) if tf.respond_to?(:read)
              end

              image_param.to_s
            end

            # ─── routes ──────────────────────────────────────────────────────

            # rubocop:disable Metrics/BlockLength
            post '/generations' do
              require_llm!

              unless Images.capable_provider_available?(:image_generation)
                halt 501, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({
                                         error: {
                                           message: 'No provider with image_generation capability is configured. ' \
                                                    'Enable a provider extension that supports image generation (e.g. lex-llm-openai).',
                                           type:    'capability_not_supported',
                                           code:    nil
                                         }
                                       })
              end

              body = Images.parse_media_body(request)

              prompt = body[:prompt] || body['prompt']
              if prompt.nil? || prompt.to_s.empty?
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: 'prompt is required', type: 'invalid_request_error', code: nil } })
              end

              model      = (body[:model] || body['model'] || Legion::LLM::Settings.value(:default_model) || 'dall-e-3').to_s
              n          = [(body[:n] || body['n'] || 1).to_i, 1].max
              size       = (body[:size] || body['size'] || '1024x1024').to_s
              quality    = (body[:quality] || body['quality'] || 'standard').to_s
              fmt        = (body[:response_format] || body['response_format'] || 'b64_json').to_s
              request_id = "img_#{SecureRandom.hex(16)}"

              log.info("[llm][api][openai][images] action=generations request_id=#{request_id} model=#{model} n=#{n} size=#{size}")

              effective_caller = build_server_caller(source: 'openai_images', path: request.path, env: env)

              inference_request = Legion::LLM::Inference::Request.build(
                id:       request_id,
                messages: [{ role: 'user', content: prompt }],
                routing:  { model: model },
                caller:   effective_caller,
                stream:   false,
                cache:    { strategy: :none, cacheable: false },
                meta:     { task: :image_generation, prompt: prompt, n: n, size: size, quality: quality, response_format: fmt }
              )

              pipeline_response = Legion::LLM::Inference::Executor.new(inference_request).call
              response_body = Images.format_images_response(pipeline_response, response_format: fmt)

              log.info("[llm][api][openai][images] action=generations_complete request_id=#{request_id} count=#{response_body[:data].size}")
              content_type :json
              status 200
              Legion::JSON.dump(response_body)
            rescue Legion::LLM::AuthError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.images.generations.auth')
              halt 401, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'authentication_error', code: nil } })
            rescue Legion::LLM::RateLimitError => e
              handle_exception(e, level: :warn, handled: true, operation: 'llm.api.openai.images.generations.rate_limit')
              halt 429, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'rate_limit_error', code: nil } })
            rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.images.generations.provider')
              halt 502, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error', code: nil } })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.images.generations')
              halt 500, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error', code: nil } })
            end
            # rubocop:enable Metrics/BlockLength

            # rubocop:disable Metrics/BlockLength
            post '/edits' do
              require_llm!

              unless Images.capable_provider_available?(:image_generation)
                halt 501, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({
                                         error: {
                                           message: 'No provider with image_generation capability is configured.',
                                           type:    'capability_not_supported',
                                           code:    nil
                                         }
                                       })
              end

              body = Images.parse_media_body(request)

              prompt = body[:prompt] || body['prompt']
              if prompt.nil? || prompt.to_s.empty?
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: 'prompt is required', type: 'invalid_request_error', code: nil } })
              end

              image_data = body[:image] || body['image']
              if image_data.nil? || image_data.to_s.empty?
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: 'image is required', type: 'invalid_request_error', code: nil } })
              end

              model      = (body[:model] || body['model'] || 'dall-e-2').to_s
              n          = [(body[:n] || body['n'] || 1).to_i, 1].max
              size       = (body[:size] || body['size'] || '1024x1024').to_s
              mask_data  = body[:mask] || body['mask']
              fmt        = (body[:response_format] || body['response_format'] || 'b64_json').to_s
              request_id = "img_#{SecureRandom.hex(16)}"

              image_b64 = Images.normalize_image_param(image_data)

              log.info("[llm][api][openai][images] action=edits request_id=#{request_id} model=#{model} n=#{n} size=#{size}")

              effective_caller = build_server_caller(source: 'openai_images', path: request.path, env: env)

              inference_request = Legion::LLM::Inference::Request.build(
                id:       request_id,
                messages: [{ role: 'user', content: prompt }],
                routing:  { model: model },
                caller:   effective_caller,
                stream:   false,
                cache:    { strategy: :none, cacheable: false },
                meta:     {
                  task:            :image_edit,
                  prompt:          prompt,
                  image_b64:       image_b64,
                  mask_b64:        mask_data ? Images.normalize_image_param(mask_data) : nil,
                  n:               n,
                  size:            size,
                  response_format: fmt
                }
              )

              pipeline_response = Legion::LLM::Inference::Executor.new(inference_request).call
              response_body = Images.format_images_response(pipeline_response, response_format: fmt)

              log.info("[llm][api][openai][images] action=edits_complete request_id=#{request_id} count=#{response_body[:data].size}")
              content_type :json
              status 200
              Legion::JSON.dump(response_body)
            rescue Legion::LLM::AuthError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.images.edits.auth')
              halt 401, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'authentication_error', code: nil } })
            rescue Legion::LLM::RateLimitError => e
              handle_exception(e, level: :warn, handled: true, operation: 'llm.api.openai.images.edits.rate_limit')
              halt 429, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'rate_limit_error', code: nil } })
            rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.images.edits.provider')
              halt 502, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error', code: nil } })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.images.edits')
              halt 500, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error', code: nil } })
            end
            # rubocop:enable Metrics/BlockLength

            # rubocop:disable Metrics/BlockLength
            post '/variations' do
              require_llm!

              unless Images.capable_provider_available?(:image_generation)
                halt 501, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({
                                         error: {
                                           message: 'No provider with image_generation capability is configured.',
                                           type:    'capability_not_supported',
                                           code:    nil
                                         }
                                       })
              end

              body = Images.parse_media_body(request)

              image_data = body[:image] || body['image']
              if image_data.nil? || image_data.to_s.empty?
                halt 400, { 'Content-Type' => 'application/json' },
                     Legion::JSON.dump({ error: { message: 'image is required', type: 'invalid_request_error', code: nil } })
              end

              model      = (body[:model] || body['model'] || 'dall-e-2').to_s
              n          = [(body[:n] || body['n'] || 1).to_i, 1].max
              size       = (body[:size] || body['size'] || '1024x1024').to_s
              fmt        = (body[:response_format] || body['response_format'] || 'b64_json').to_s
              request_id = "img_#{SecureRandom.hex(16)}"

              image_b64 = Images.normalize_image_param(image_data)

              log.info("[llm][api][openai][images] action=variations request_id=#{request_id} model=#{model} n=#{n} size=#{size}")

              effective_caller = build_server_caller(source: 'openai_images', path: request.path, env: env)

              inference_request = Legion::LLM::Inference::Request.build(
                id:       request_id,
                messages: [{ role: 'user', content: 'Create a variation of this image.' }],
                routing:  { model: model },
                caller:   effective_caller,
                stream:   false,
                cache:    { strategy: :none, cacheable: false },
                meta:     { task: :image_variation, image_b64: image_b64, n: n, size: size, response_format: fmt }
              )

              pipeline_response = Legion::LLM::Inference::Executor.new(inference_request).call
              response_body = Images.format_images_response(pipeline_response, response_format: fmt)

              log.info("[llm][api][openai][images] action=variations_complete request_id=#{request_id} count=#{response_body[:data].size}")
              content_type :json
              status 200
              Legion::JSON.dump(response_body)
            rescue Legion::LLM::AuthError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.images.variations.auth')
              halt 401, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'authentication_error', code: nil } })
            rescue Legion::LLM::RateLimitError => e
              handle_exception(e, level: :warn, handled: true, operation: 'llm.api.openai.images.variations.rate_limit')
              halt 429, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'rate_limit_error', code: nil } })
            rescue Legion::LLM::ProviderDown, Legion::LLM::ProviderError => e
              handle_exception(e, level: :error, handled: true, operation: 'llm.api.openai.images.variations.provider')
              halt 502, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error', code: nil } })
            rescue StandardError => e
              handle_exception(e, level: :error, handled: false, operation: 'llm.api.openai.images.variations')
              halt 500, { 'Content-Type' => 'application/json' },
                   Legion::JSON.dump({ error: { message: e.message, type: 'server_error', code: nil } })
            end
            # rubocop:enable Metrics/BlockLength
          end
        end
      end
    end
  end
end
