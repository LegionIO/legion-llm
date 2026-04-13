# frozen_string_literal: true

module Legion
  module LLM
    module Providers
      include Legion::Logging::Helper

      def configure_providers
        auto_enable_from_resolved_credentials
        settings[:providers].each do |provider, config|
          next unless config[:enabled]

          apply_provider_config(provider, config)
        end
      end

      def auto_enable_from_resolved_credentials
        settings[:providers].each do |provider, config|
          next if config[:enabled]

          has_creds = case provider
                      when :bedrock
                        config[:bearer_token] || (config[:api_key] && config[:secret_key])
                      when :azure
                        config[:api_base] && (config[:api_key] || config[:auth_token])
                      when :ollama
                        ollama_running?(config)
                      else
                        config[:api_key]
                      end

          has_creds ||= broker_has_credential?(provider) unless has_creds

          next unless has_creds

          config[:enabled] = true
          log.info "Auto-enabled #{provider} provider (credentials found)"
        end
      end

      def ollama_running?(config)
        require 'socket'
        url = config[:base_url] || 'http://localhost:11434'
        host_part = url.gsub(%r{^https?://}, '').split(':')
        addr = host_part[0]
        port = (host_part[1] || '11434').to_i
        Socket.tcp(addr, port, connect_timeout: 1).close
        true
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.providers.ollama_running', base_url: url)
        false
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
        when :azure
          configure_azure(config)
        when :ollama
          configure_ollama(config)
        else
          log.warn "Unknown LLM provider: #{provider}"
        end
      end

      def configure_bedrock(config)
        has_sigv4 = config[:api_key] && config[:secret_key]
        has_bearer = config[:bearer_token]

        unless has_sigv4 || has_bearer
          broker_creds = resolve_broker_aws_credentials
          if broker_creds
            has_sigv4 = true
            config = config.merge(
              api_key:       broker_creds.access_key_id,
              secret_key:    broker_creds.secret_access_key,
              session_token: (broker_creds.session_token if broker_creds.respond_to?(:session_token))
            )
          end
        end

        return unless has_sigv4 || has_bearer

        require 'legion/llm/bedrock_bearer_auth' if has_bearer

        RubyLLM.configure do |c|
          if has_bearer
            c.bedrock_bearer_token = config[:bearer_token]
          else
            c.bedrock_api_key = config[:api_key]
            c.bedrock_secret_key = config[:secret_key]
            c.bedrock_session_token = config[:session_token] if config[:session_token]
          end
          c.bedrock_region = config[:region] || 'us-east-2'
        end

        auth_mode = has_bearer ? 'bearer token' : 'SigV4'
        log.info "Configured Bedrock provider (#{config[:region]}, #{auth_mode})"
      end

      def configure_anthropic(config)
        api_key = resolve_broker_credential(:anthropic) || config[:api_key]
        return unless api_key

        RubyLLM.configure do |c|
          c.anthropic_api_key = api_key
        end
        log.info 'Configured Anthropic provider'
      end

      def configure_openai(config)
        api_key = resolve_broker_credential(:openai) || config[:api_key]
        return unless api_key

        RubyLLM.configure do |c|
          c.openai_api_key = api_key
        end
        log.info 'Configured OpenAI provider'
      end

      def configure_gemini(config)
        api_key = resolve_broker_credential(:gemini) || config[:api_key]
        return unless api_key

        RubyLLM.configure do |c|
          c.gemini_api_key = api_key
        end
        log.info 'Configured Gemini provider'
      end

      def configure_azure(config)
        api_base = config[:api_base]
        api_key = resolve_broker_credential(:azure) || config[:api_key]
        auth_token = config[:auth_token]
        return unless api_base && (api_key || auth_token)

        RubyLLM.configure do |c|
          c.azure_api_base = api_base
          c.azure_api_key = api_key if api_key
          c.azure_ai_auth_token = auth_token if auth_token
        end
        log.info "Configured Azure AI Foundry provider (#{api_base})"
      end

      def configure_ollama(config)
        RubyLLM.configure do |c|
          c.ollama_api_base = config[:base_url] if config[:base_url]
        end
        log.info "Configured Ollama provider (#{config[:base_url]})"
      end

      SAAS_PROVIDERS = %i[bedrock anthropic openai gemini azure].freeze

      def verify_providers
        settings[:providers].each do |provider, config|
          next unless config[:enabled]
          next unless SAAS_PROVIDERS.include?(provider)

          model = config[:default_model]
          next unless model

          verify_single_provider(provider, model, config)
        end

        recover_with_alternative_credentials

        enabled = settings[:providers].select { |_, c| c.is_a?(Hash) && c[:enabled] }
        if enabled.empty?
          log.error 'No LLM providers available — all providers failed health checks or are disabled. ' \
                    'LLM features (chat, inference, embeddings) will not work. ' \
                    'Check API keys, network connectivity, and provider configuration.'
        else
          names = enabled.map { |name, c| "#{name}/#{c[:default_model] || 'auto'}" }
          log.info "LLM providers available: #{names.join(', ')}"
        end
      end

      def recover_with_alternative_credentials
        recover_openai_with_codex
      end

      def recover_openai_with_codex
        openai_config = settings.dig(:providers, :openai)
        return unless openai_config.is_a?(Hash) && !openai_config[:enabled]

        token = CodexConfigLoader.read_token
        return unless token

        log.info 'OpenAI disabled — trying Codex auth token as fallback'
        openai_config[:api_key] = token
        configure_openai(openai_config)
        openai_config[:enabled] = true
        verify_single_provider(:openai, openai_config[:default_model], openai_config)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.providers.recover_openai_with_codex')
      end

      def verify_single_provider(provider, model, _config)
        start_time = Time.now
        RubyLLM.chat(model: model, provider: provider).ask('Respond with only the word: pong')
        elapsed = ((Time.now - start_time) * 1000).round
        log.info "Health check #{provider}/#{model}: OK (#{elapsed}ms)"
      rescue RubyLLM::ModelNotFoundError => e
        handle_exception(e, level: :warn, operation: 'llm.providers.verify_single_provider', provider: provider, model: model)
      rescue RubyLLM::ForbiddenError => e
        handle_exception(e, level: :debug, operation: 'llm.providers.verify_single_provider', provider: provider, model: model)
      rescue StandardError => e
        log.warn "LLM provider (#{provider}) not available, #{e.class}"
        handle_exception(e, level: :debug, operation: 'llm.providers.verify_single_provider', provider: provider, model: model)
        # config[:enabled] = false
      end

      def resolve_broker_credential(provider_name)
        return nil unless defined?(Legion::Identity::Broker)

        Legion::Identity::Broker.token_for(provider_name)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: "llm.providers.broker_resolve.#{provider_name}")
        nil
      end

      def resolve_broker_aws_credentials
        return nil unless defined?(Legion::Identity::Broker)

        renewer = Legion::Identity::Broker.renewer_for(:aws)
        return renewer.provider.current_credentials if renewer&.provider.respond_to?(:current_credentials)

        nil
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.providers.broker_resolve.aws')
        nil
      end

      def broker_has_credential?(provider)
        return false unless defined?(Legion::Identity::Broker)

        case provider
        when :bedrock
          renewer = Legion::Identity::Broker.renewer_for(:aws)
          renewer&.provider.respond_to?(:current_credentials) && !renewer.provider.current_credentials.nil?
        else
          !Legion::Identity::Broker.token_for(provider).nil?
        end
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'llm.providers.broker_credential_available', provider: provider)
        false
      end
    end
  end
end
