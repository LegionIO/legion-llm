# frozen_string_literal: true

require 'json'

require 'legion/logging/helper'
module Legion
  module LLM
    module Call
      module ClaudeConfigLoader
        extend Legion::Logging::Helper

        CLAUDE_SETTINGS = File.expand_path('~/.claude/settings.json')
        CLAUDE_CONFIG   = File.expand_path('~/.claude.json')
        SECRET_URI_PATTERN = %r{\A(?:env|vault|lease)://}

        module_function

        def load
          config = merged_config
          return if config.empty?

          apply_claude_config(config)
        end

        def merged_config
          read_json(CLAUDE_SETTINGS).merge(read_json(CLAUDE_CONFIG))
        end

        def read_json(path)
          return {} unless File.exist?(path)

          ::JSON.parse(File.read(path), symbolize_names: true)
        rescue StandardError => e
          handle_exception(e, level: :debug)
          {}
        end

        def anthropic_api_key
          config = merged_config
          first_present(
            config[:anthropicApiKey],
            config.dig(:env, :ANTHROPIC_API_KEY)
          )
        end

        def openai_api_key
          config = merged_config
          first_present(
            config[:openaiApiKey],
            config.dig(:env, :OPENAI_API_KEY),
            config.dig(:env, :CODEX_API_KEY)
          )
        end

        def bedrock_bearer_token
          env = read_json(CLAUDE_SETTINGS)[:env]
          return nil unless env.is_a?(Hash)

          direct = first_present(env[:AWS_BEARER_TOKEN_BEDROCK], env['AWS_BEARER_TOKEN_BEDROCK'])
          return direct if direct

          match = env.find do |key, value|
            name = key.to_s.upcase
            next false unless name.include?('AWS')
            next false unless name.include?('BEARER')
            next false unless name.include?('TOKEN')
            next false unless name.include?('BEDROCK')

            !normalize_secret(value).nil?
          end
          normalize_secret(match&.last)
        end

        def oauth_account_available?
          oauth = read_json(CLAUDE_CONFIG)[:oauthAccount]
          oauth.is_a?(Hash) && oauth.any? { |_k, value| !normalize_secret(value).nil? }
        end

        def apply_claude_config(config)
          apply_api_keys(config)
          apply_model_preference(config)
        end

        def apply_api_keys(config)
          llm = Legion::LLM.settings
          providers = llm[:providers]

          anthropic_key = first_present(config[:anthropicApiKey], config.dig(:env, :ANTHROPIC_API_KEY))
          if anthropic_key && !setting_has_usable_credential?(providers.dig(:anthropic, :api_key))
            providers[:anthropic][:api_key] = anthropic_key
            log.debug 'Imported Anthropic API key from Claude CLI config'
          end

          openai_key = first_present(config[:openaiApiKey], config.dig(:env, :OPENAI_API_KEY), config.dig(:env, :CODEX_API_KEY))
          if openai_key && !setting_has_usable_credential?(providers.dig(:openai, :api_key))
            providers[:openai][:api_key] = openai_key
            log.debug 'Imported OpenAI API key from Claude CLI config'
          end

          bedrock_token = bedrock_bearer_token
          return unless bedrock_token && !setting_has_usable_credential?(providers.dig(:bedrock, :bearer_token))

          providers[:bedrock][:bearer_token] = bedrock_token
          log.debug 'Imported Bedrock bearer token from Claude settings.json env section'
        end

        def apply_model_preference(config)
          return unless config[:preferredModel] || config[:model]

          model = config[:preferredModel] || config[:model]
          llm = Legion::LLM.settings
          return if llm[:default_model]

          llm[:default_model] = model
          log.debug "Imported model preference from Claude CLI config: #{model}"
        end

        def setting_has_usable_credential?(value)
          !resolve_setting_reference(value).nil?
        end

        def resolve_setting_reference(value)
          case value
          when Array
            value.each do |entry|
              resolved = resolve_setting_reference(entry)
              return resolved unless resolved.nil?
            end
            nil
          when String
            resolved = normalize_secret(value)
            return nil if resolved.nil?

            if resolved.start_with?('env://')
              env_name = resolved.sub('env://', '')
              return normalize_secret(ENV.fetch(env_name, nil))
            end
            return nil if resolved.match?(SECRET_URI_PATTERN)

            resolved
          else
            normalize_secret(value)
          end
        end

        def first_present(*values)
          values.each do |value|
            normalized = normalize_secret(value)
            return normalized unless normalized.nil?
          end
          nil
        end

        def normalize_secret(value)
          return nil if value.nil?
          return value unless value.is_a?(String)

          normalized = value.strip
          return nil if normalized.empty?

          normalized
        end
      end
    end
  end
end
