# frozen_string_literal: true

module Legion
  module LLM
    module Providers
      def configure_providers
        settings[:providers].each do |provider, config|
          next unless config[:enabled]

          resolve_credentials(provider, config)
          apply_provider_config(provider, config)
        end
      end

      def resolve_credentials(provider, config)
        return unless config[:vault_path] && vault_available?

        Legion::Logging.debug "Resolving #{provider} credentials from Vault: #{config[:vault_path]}"
        secret = Legion::Crypt.read(config[:vault_path])
        return unless secret.is_a?(Hash)

        case provider
        when :bedrock
          config[:api_key]       ||= secret[:access_key] || secret[:aws_access_key_id]
          config[:secret_key]    ||= secret[:secret_key] || secret[:aws_secret_access_key]
          config[:session_token] ||= secret[:session_token] || secret[:aws_session_token]
          config[:region]        ||= secret[:region]
        when :anthropic, :openai, :gemini
          config[:api_key] ||= secret[:api_key] || secret[:token]
        end
      rescue StandardError => e
        Legion::Logging.warn "Failed to resolve #{provider} credentials from Vault: #{e.message}"
      end

      def apply_provider_config(provider, config)
        case provider
        when :bedrock
          configure_bedrock(config)
        when :anthropic
          configure_anthropic(config)
        when :openai
          configure_openai(config)
        when :gemini
          configure_gemini(config)
        when :ollama
          configure_ollama(config)
        else
          Legion::Logging.warn "Unknown LLM provider: #{provider}"
        end
      end

      def configure_bedrock(config)
        return unless config[:api_key] && config[:secret_key]

        RubyLLM.configure do |c|
          c.bedrock_api_key       = config[:api_key]
          c.bedrock_secret_key    = config[:secret_key]
          c.bedrock_session_token = config[:session_token] if config[:session_token]
          c.bedrock_region        = config[:region] || 'us-east-2'
        end
        Legion::Logging.info "Configured Bedrock provider (#{config[:region]})"
      end

      def configure_anthropic(config)
        return unless config[:api_key]

        RubyLLM.configure do |c|
          c.anthropic_api_key = config[:api_key]
        end
        Legion::Logging.info 'Configured Anthropic provider'
      end

      def configure_openai(config)
        return unless config[:api_key]

        RubyLLM.configure do |c|
          c.openai_api_key = config[:api_key]
        end
        Legion::Logging.info 'Configured OpenAI provider'
      end

      def configure_gemini(config)
        return unless config[:api_key]

        RubyLLM.configure do |c|
          c.gemini_api_key = config[:api_key]
        end
        Legion::Logging.info 'Configured Gemini provider'
      end

      def configure_ollama(config)
        RubyLLM.configure do |c|
          c.ollama_api_base = config[:base_url] if config[:base_url]
        end
        Legion::Logging.info "Configured Ollama provider (#{config[:base_url]})"
      end

      def vault_available?
        Legion.const_defined?('Crypt') &&
          Legion::Settings[:crypt][:vault][:connected]
      end
    end
  end
end
