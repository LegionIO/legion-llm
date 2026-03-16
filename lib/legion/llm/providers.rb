# frozen_string_literal: true

module Legion
  module LLM
    module Providers
      def configure_providers
        settings[:providers].each do |provider, config|
          next unless config[:enabled]

          apply_provider_config(provider, config)
        end
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
        has_sigv4  = config[:api_key] && config[:secret_key]
        has_bearer = config[:bearer_token]
        return unless has_sigv4 || has_bearer

        require 'legion/llm/bedrock_bearer_auth' if has_bearer

        RubyLLM.configure do |c|
          if has_bearer
            c.bedrock_bearer_token = config[:bearer_token]
          else
            c.bedrock_api_key       = config[:api_key]
            c.bedrock_secret_key    = config[:secret_key]
            c.bedrock_session_token = config[:session_token] if config[:session_token]
          end
          c.bedrock_region = config[:region] || 'us-east-2'
        end

        auth_mode = has_bearer ? 'bearer token' : 'SigV4'
        Legion::Logging.info "Configured Bedrock provider (#{config[:region]}, #{auth_mode})"
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
    end
  end
end
