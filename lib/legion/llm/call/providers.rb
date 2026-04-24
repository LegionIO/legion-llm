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

            has_creds = credential_available_for?(provider, config)
            has_creds ||= broker_has_credential?(provider) unless has_creds

            next unless has_creds

            config[:enabled] = true
            log.info "[llm][providers] auto-enabled provider=#{provider} reason=credentials_found"
          end
        end

        def credential_available_for?(provider, config)
          case provider
          when :bedrock
            usable_setting?(config[:bearer_token]) ||
              env_present?('AWS_BEARER_TOKEN_BEDROCK') ||
              (usable_setting?(config[:api_key]) && usable_setting?(config[:secret_key]))
          when :anthropic
            usable_setting?(config[:api_key]) || env_present?('ANTHROPIC_API_KEY')
          when :openai
            usable_setting?(config[:api_key]) ||
              env_present?('OPENAI_API_KEY') ||
              env_present?('CODEX_API_KEY') ||
              !Call::CodexConfigLoader.read_token.nil?
          when :azure
            config[:api_base] && (usable_setting?(config[:api_key]) || usable_setting?(config[:auth_token]))
          when :ollama
            ollama_running?(config)
          when :vllm
            vllm_running?(config)
          else
            usable_setting?(config[:api_key])
          end
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.providers.credential_available_for', provider: provider)
          false
        end

        def usable_setting?(value)
          !Call::ClaudeConfigLoader.resolve_setting_reference(value).nil?
        end

        def env_present?(key)
          ENV.fetch(key, nil).to_s.strip != ''
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

        def vllm_running?(config)
          require 'faraday'
          url = config[:base_url] || 'http://localhost:8000/v1'
          base = url.chomp('/v1').chomp('/')
          log.debug "[llm][providers] vllm_running? url=#{base}/health"
          response = Faraday.new(url: base) do |f|
            f.options.timeout = 2
            f.options.open_timeout = 2
            f.adapter Faraday.default_adapter
          end.get('/health')
          response.success?
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.providers.vllm_running', base_url: url)
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
          when :vllm then configure_vllm(config)
          else
            log.warn "[llm][providers] unknown provider=#{provider}"
          end
        end

        def configure_bedrock(config)
          has_sigv4 = usable_setting?(config[:api_key]) && usable_setting?(config[:secret_key])
          has_bearer = Call::ClaudeConfigLoader.resolve_setting_reference(config[:bearer_token])
          config[:bearer_token] = has_bearer if has_bearer

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
          api_key = resolve_broker_credential(:anthropic) ||
                    Call::ClaudeConfigLoader.resolve_setting_reference(config[:api_key]) ||
                    ENV.fetch('ANTHROPIC_API_KEY', nil)
          return unless api_key

          RubyLLM.configure do |c|
            c.anthropic_api_key = api_key
            c.anthropic_api_base = config[:base_url] if config[:base_url]
          end
          log.info "[llm][providers] configured anthropic base_url=#{config[:base_url].inspect}"
        end

        def configure_openai(config)
          api_key = resolve_broker_credential(:openai) ||
                    Call::ClaudeConfigLoader.resolve_setting_reference(config[:api_key]) ||
                    ENV.fetch('OPENAI_API_KEY', nil) ||
                    ENV.fetch('CODEX_API_KEY', nil)
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

        def configure_vllm(config)
          base_url = config[:base_url] || 'http://localhost:8000/v1'
          RubyLLM.configure do |c|
            c.vllm_api_base = base_url
            c.vllm_api_key = config[:api_key] if config[:api_key]
          end
          log.info "[llm][providers] configured vllm base_url=#{base_url.inspect}"
        end

        SAAS_PROVIDERS = %i[bedrock anthropic openai gemini azure].freeze

        def verify_providers
          log.debug '[llm][providers] verify_providers.enter'
          Legion::LLM.settings[:providers].each do |provider, config|
            next unless config[:enabled]
            next unless SAAS_PROVIDERS.include?(provider)

            model = config[:default_model]
            next unless model

            probe_provider_credentials(provider, model, config)
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

        def probe_provider_credentials(provider, model, config)
          candidates = collect_credential_candidates(provider, config)

          if candidates.size <= 1
            ok = attempt_provider_call(provider, model)
            config[:enabled] = false unless ok
            return
          end

          working = candidates.find do |creds|
            apply_credential_to_rubyllm(provider, creds, config)
            attempt_provider_call(provider, model)
          end

          if working
            apply_credential_to_config(provider, config, working)
            log.info "[llm][providers] health_check ok provider=#{provider} model=#{model} credential=#{working.keys.join(',')}"
          else
            config[:enabled] = false
            log.warn "[llm][providers] disabled provider=#{provider} reason=all_credentials_failed"
          end
        end

        def collect_credential_candidates(provider, config)
          case provider
          when :bedrock
            candidates = []
            resolved_bearer = Call::ClaudeConfigLoader.resolve_setting_reference(config[:bearer_token])
            bearer_env = ENV.fetch('AWS_BEARER_TOKEN_BEDROCK', nil)
            claude_bearer = Call::ClaudeConfigLoader.bedrock_bearer_token
            candidates += [resolved_bearer, bearer_env, claude_bearer].compact.uniq.map { |t| { bearer_token: t } }
            api_key = Call::ClaudeConfigLoader.resolve_setting_reference(config[:api_key])
            secret = Call::ClaudeConfigLoader.resolve_setting_reference(config[:secret_key])
            candidates << { api_key: api_key, secret_key: secret } if api_key && secret
            candidates
          when :anthropic
            [
              Call::ClaudeConfigLoader.resolve_setting_reference(config[:api_key]),
              ENV.fetch('ANTHROPIC_API_KEY', nil)
            ].compact.uniq.map { |k| { api_key: k } }
          when :openai
            keys = [
              Call::ClaudeConfigLoader.resolve_setting_reference(config[:api_key]),
              ENV.fetch('OPENAI_API_KEY', nil),
              ENV.fetch('CODEX_API_KEY', nil),
              Call::CodexConfigLoader.read_token
            ].compact.uniq
            keys.map { |k| { api_key: k } }
          when :gemini
            [
              Call::ClaudeConfigLoader.resolve_setting_reference(config[:api_key]),
              ENV.fetch('GEMINI_API_KEY', nil)
            ].compact.uniq.map { |k| { api_key: k } }
          else
            []
          end
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.providers.collect_credential_candidates', provider: provider)
          []
        end

        def apply_credential_to_rubyllm(provider, creds, config)
          case provider
          when :bedrock
            region = config[:region] || 'us-east-2'
            if creds[:bearer_token]
              require 'legion/llm/call/bedrock_auth'
              RubyLLM.configure do |c|
                c.bedrock_bearer_token = creds[:bearer_token]
                c.bedrock_region = region
              end
            else
              RubyLLM.configure do |c|
                c.bedrock_api_key    = creds[:api_key]
                c.bedrock_secret_key = creds[:secret_key]
                c.bedrock_region     = region
              end
            end
          when :anthropic
            RubyLLM.configure { |c| c.anthropic_api_key = creds[:api_key] }
          when :openai
            RubyLLM.configure { |c| c.openai_api_key = creds[:api_key] }
          when :gemini
            RubyLLM.configure { |c| c.gemini_api_key = creds[:api_key] }
          end
        end

        def apply_credential_to_config(provider, config, creds)
          case provider
          when :bedrock
            config[:bearer_token] = creds[:bearer_token] if creds[:bearer_token]
            config[:api_key]      = creds[:api_key]      if creds[:api_key]
            config[:secret_key]   = creds[:secret_key]   if creds[:secret_key]
          when :anthropic, :openai, :gemini
            config[:api_key] = creds[:api_key]
          end
        end

        def attempt_provider_call(provider, model)
          start_time = Time.now
          result = probe_via_model_list(provider, model)
          elapsed = ((Time.now - start_time) * 1000).round

          case result
          when :auth_error
            log.warn "[llm][providers] health_check auth_failed provider=#{provider}"
            false
          when :model_missing
            log.warn "[llm][providers] health_check model_missing provider=#{provider} model=#{model} — provider ok, model unavailable"
            false
          else
            log.info "[llm][providers] health_check ok provider=#{provider} model=#{model} elapsed_ms=#{elapsed}"
            true
          end
        rescue StandardError => e
          log.warn "[llm][providers] health_check failed provider=#{provider} error=#{e.class}"
          handle_exception(e, level: :debug, operation: 'llm.providers.attempt_provider_call', provider: provider, model: model)
          false
        end

        def probe_via_model_list(provider, target_model)
          provider_class = RubyLLM::Provider.providers[provider.to_sym]
          return probe_via_chat(provider, target_model) unless provider_class

          models = provider_class.new(RubyLLM.config).list_models
          model_ids = models.map { |m| m.is_a?(Hash) ? (m[:id] || m['id']).to_s : m.id.to_s }

          return :ok if target_model.nil?
          return :ok if model_ids.any? { |id| id.include?(target_model) || target_model.include?(id) }

          :model_missing
        rescue RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError
          :auth_error
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.providers.probe_via_model_list', provider: provider)
          probe_via_chat(provider, target_model)
        end

        def probe_via_chat(provider, model)
          RubyLLM.chat(model: model, provider: provider).ask('Respond with only the word: pong')
          :ok
        rescue RubyLLM::ModelNotFoundError
          :model_missing
        rescue RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError
          :auth_error
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

          log.info '[llm][providers] openai disabled — retrying with codex auth token'
          openai_config[:api_key] = token
          configure_openai(openai_config)
          openai_config[:enabled] = true
          ok = attempt_provider_call(:openai, openai_config[:default_model])
          openai_config[:enabled] = false unless ok
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'llm.providers.recover_openai_with_codex')
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
