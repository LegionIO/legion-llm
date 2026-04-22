# frozen_string_literal: true

require 'base64'
require 'json'

require 'legion/logging/helper'
module Legion
  module LLM
    module Call
      module CodexConfigLoader
        extend Legion::Logging::Helper

        CODEX_AUTH = File.expand_path('~/.codex/auth.json')

        module_function

        def load
          return unless File.exist?(CODEX_AUTH)

          config = read_json(CODEX_AUTH)
          return if config.empty?

          apply_codex_config(config)
        end

        def read_token
          return nil unless File.exist?(CODEX_AUTH)

          config = read_json(CODEX_AUTH)
          return nil if config.empty?
          return nil unless config[:auth_mode] == 'chatgpt'

          token = config.dig(:tokens, :access_token)
          return nil unless token.is_a?(String) && !token.empty?
          return nil unless token_valid?(token)

          token
        end

        def read_json(path)
          ::JSON.parse(File.read(path), symbolize_names: true)
        rescue StandardError => e
          handle_exception(e, level: :debug)
          {}
        end

        def apply_codex_config(config)
          return unless config[:auth_mode] == 'chatgpt'

          token = config.dig(:tokens, :access_token)
          return unless token.is_a?(String) && !token.empty?

          unless token_valid?(token)
            log.debug 'CodexConfigLoader: access token is expired, skipping'
            return
          end

          providers = Legion::LLM.settings[:providers]
          existing_raw = providers.dig(:openai, :api_key)
          resolved_existing = resolve_env_api_key(existing_raw)
          return unless resolved_existing.nil? || (resolved_existing.respond_to?(:empty?) && resolved_existing.empty?)

          providers[:openai][:api_key] = token
          log.debug 'Imported OpenAI API key from Codex auth config'
        end

        def resolve_env_api_key(value)
          return nil if value.nil?

          if value.is_a?(String)
            return nil if value.empty?

            if value.start_with?('env://')
              env_name = value.sub('env://', '')
              env_value = ENV.fetch(env_name, nil)
              return nil if env_value.nil? || env_value.empty?

              return env_value
            end

            return value
          end

          if value.is_a?(Array)
            resolved = value.map { |v| resolve_env_api_key(v) }.compact
            return nil if resolved.empty?
            return resolved.first if resolved.length == 1

            return resolved
          end

          value
        end

        def token_valid?(token)
          parts = token.split('.')
          return true unless parts.length == 3

          padded = parts[1] + ('=' * ((4 - (parts[1].length % 4)) % 4))
          payload = ::JSON.parse(Base64.urlsafe_decode64(padded), symbolize_names: true)
          exp = payload[:exp]
          return true unless exp.is_a?(Integer)

          exp > Time.now.to_i
        rescue StandardError => e
          log.debug("CodexConfigLoader.token_valid? failed to parse access token: #{e.message}")
          handle_exception(e, level: :debug)
          true
        end
      end
    end
  end
end
