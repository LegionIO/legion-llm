# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module LLM
    module Call
      module Providers
        extend Legion::Logging::Helper

        module_function

        def setup
          log.debug '[llm][providers] setup.enter'
          resolve_llm_secrets
          configure_providers
          verify_providers
          auto_register_providers
          log.debug '[llm][providers] setup.exit'
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'llm.providers.setup')
          raise
        end

        def resolve_llm_secrets
          log.debug '[llm][providers] resolve_llm_secrets.enter'
          return unless defined?(Legion::Settings::Resolver)

          Legion::Settings::Resolver.resolve_secrets!(Legion::LLM.settings)
          log.debug '[llm][providers] resolve_llm_secrets.exit'
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.resolve_llm_secrets')
        end

        def configure_providers
          log.debug '[llm][providers] configure_providers.enter'
          auto_enable_from_resolved_credentials
          Legion::LLM.settings[:providers].each do |provider, config|
            next unless config[:enabled]

            log.debug "[llm][providers] configure_providers applying provider=#{provider}"
            apply_provider_config(provider, config)
          end
          log.debug '[llm][providers] configure_providers.exit'
        end

        def auto_enable_from_resolved_credentials
          log.debug '[llm][providers] auto_enable_from_resolved_credentials.enter'
          Legion::LLM.settings[:providers].each do |provider, config|
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
            log.info "[llm][providers] auto-enabled provider=#{provider} reason=credentials_found"
          end
        end

        def ollama_running?(config)
          require 'socket'
          url = config[:base_url] || 'http://localhost:11434'
          host_part = url.gsub(%r{^https?://}, '').split(':')
          addr = host_part[0]
          port = (host_part[1] || '11434').to_i
          log.debug "[llm][providers] ollama_running? addr=#{addr} port=#{port}"
          Socket.tcp(addr, port, connect_timeout: 1).close
          true
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.providers.ollama_running', base_url: url)
          false
        end

        def apply_provider_config(provider, config)
          case provider
          when :bedrock   then configure_bedrock(config)
          when :anthropic then configure_anthropic(config)
          when :openai    then configure_openai(config)
          when :gemini    then configure_gemini(config)
          when :azure     then configure_azure(config)
          when :ollama    then configure_ollama(config)
          else
            log.warn "[llm][providers] unknown provider=#{provider}"
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

          require 'legion/llm/call/bedrock_auth' if has_bearer

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
          log.info "[llm][providers] configured bedrock region=#{config[:region]} auth=#{auth_mode}"
        end

        def configure_anthropic(config)
          api_key = resolve_broker_credential(:anthropic) || config[:api_key]
          return unless api_key

          RubyLLM.configure do |c|
            c.anthropic_api_key = api_key
            c.anthropic_api_base = config[:base_url] if config[:base_url]
          end
          log.info "[llm][providers] configured anthropic base_url=#{config[:base_url].inspect}"
        end

        def configure_openai(config)
          api_key = resolve_broker_credential(:openai) || config[:api_key]
          return unless api_key

          RubyLLM.configure do |c|
            c.openai_api_key = api_key
            c.openai_api_base = config[:base_url] if config[:base_url]
          end
          log.info "[llm][providers] configured openai base_url=#{config[:base_url].inspect}"
        end

        def configure_gemini(config)
          api_key = resolve_broker_credential(:gemini) || config[:api_key]
          return unless api_key

          RubyLLM.configure do |c|
            c.gemini_api_key = api_key
            c.gemini_api_base = config[:base_url] if config[:base_url]
          end
          log.info "[llm][providers] configured gemini base_url=#{config[:base_url].inspect}"
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
          log.info "[llm][providers] configured azure api_base=#{api_base}"
        end

        def configure_ollama(config)
          RubyLLM.configure do |c|
            c.ollama_api_base = config[:base_url] if config[:base_url]
          end
          log.info "[llm][providers] configured ollama base_url=#{config[:base_url].inspect}"
        end

        SAAS_PROVIDERS = %i[bedrock anthropic openai gemini azure].freeze

        def verify_providers
          log.debug '[llm][providers] verify_providers.enter'
          Legion::LLM.settings[:providers].each do |provider, config|
            next unless config[:enabled]
            next unless SAAS_PROVIDERS.include?(provider)

            model = config[:default_model]
            next unless model

            verify_single_provider(provider, model, config)
          end

          recover_with_alternative_credentials

          enabled = Legion::LLM.settings[:providers].select { |_, c| c.is_a?(Hash) && c[:enabled] }
          if enabled.empty?
            log.error '[llm][providers] no providers available — all failed health checks or disabled'
          else
            names = enabled.map { |name, c| "#{name}/#{c[:default_model] || 'auto'}" }
            log.info "[llm][providers] available providers=#{names.join(', ')}"
          end
        end

        def recover_with_alternative_credentials
          log.debug '[llm][providers] recover_with_alternative_credentials.enter'
          recover_openai_with_codex
        end

        def recover_openai_with_codex
          openai_config = Legion::LLM.settings.dig(:providers, :openai)
          return unless openai_config.is_a?(Hash) && !openai_config[:enabled]

          token = Call::CodexConfigLoader.read_token
          return unless token

          log.info '[llm][providers] openai disabled — trying codex auth token as fallback'
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
          log.info "[llm][providers] health_check ok provider=#{provider} model=#{model} elapsed_ms=#{elapsed}"
        rescue RubyLLM::ModelNotFoundError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.verify_single_provider', provider: provider, model: model)
        rescue RubyLLM::ForbiddenError => e
          handle_exception(e, level: :debug, operation: 'llm.providers.verify_single_provider', provider: provider, model: model)
        rescue StandardError => e
          log.warn "[llm][providers] provider unavailable provider=#{provider} error=#{e.class}"
          handle_exception(e, level: :debug, operation: 'llm.providers.verify_single_provider', provider: provider, model: model)
        end

        def auto_register_providers
          log.debug '[llm][providers] auto_register_providers.enter'
          try_register_native_provider(:claude, 'Legion::Extensions::Claude', 'Legion::Extensions::Claude::Runners::Messages') do |klass|
            Call::Registry.register(:claude, klass)
            Call::Registry.register(:anthropic, klass)
          end
          try_register_native_provider(:bedrock, 'Legion::Extensions::Bedrock', 'Legion::Extensions::Bedrock::Runners::Converse') do |klass|
            Call::Registry.register(:bedrock, klass)
          end
          try_register_native_provider(:openai, 'Legion::Extensions::Openai', 'Legion::Extensions::Openai::Runners::Chat') do |klass|
            Call::Registry.register(:openai, klass)
          end
          try_register_native_provider(:gemini, 'Legion::Extensions::Gemini', 'Legion::Extensions::Gemini::Runners::Generate') do |klass|
            Call::Registry.register(:gemini, klass)
          end

          registered = Call::Registry.available
          if registered.any?
            log.info "[llm][providers] native registry registered=#{registered.join(', ')}"
          else
            log.debug '[llm][providers] no native lex-* providers registered (ruby_llm mode)'
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.auto_register')
        end

        def inject_anthropic_cache_control!(opts, provider)
          resolved_provider = (provider || Legion::LLM.settings[:default_provider])&.to_sym
          return unless resolved_provider == :anthropic

          caching_settings = Legion::LLM.settings[:prompt_caching] || {}
          return unless caching_settings[:enabled] != false

          min_tokens = caching_settings[:min_tokens] || 1024
          instructions = opts[:instructions]
          return unless instructions.is_a?(String) && instructions.length > min_tokens

          log.debug "[llm][providers] inject_anthropic_cache_control provider=#{resolved_provider} length=#{instructions.length}"
          opts[:instructions] = {
            content:       instructions,
            cache_control: { type: 'ephemeral' }
          }
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

        def try_register_native_provider(name, ext_const, runner_const)
          log.debug "[llm][providers] try_register_native_provider name=#{name} ext=#{ext_const}"
          return unless Object.const_defined?(ext_const, false) && Object.const_defined?(runner_const, false)

          klass = Object.const_get(runner_const)
          yield klass
          log.debug "[llm][providers] registered native provider name=#{name}"
        end
      end
    end
  end
end
