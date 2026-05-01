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
          auto_register_providers
          verify_providers
          log.debug '[llm][providers] setup.exit'
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'llm.providers.setup')
          raise
        end

        LEX_LLM_PROVIDER_REQUIRES = {
          ollama:        'legion/extensions/llm/ollama',
          vllm:          'legion/extensions/llm/vllm',
          anthropic:     'legion/extensions/llm/anthropic',
          openai:        'legion/extensions/llm/openai',
          gemini:        'legion/extensions/llm/gemini',
          mlx:           'legion/extensions/llm/mlx',
          bedrock:       'legion/extensions/llm/bedrock',
          azure_foundry: 'legion/extensions/llm/azure_foundry',
          vertex:        'legion/extensions/llm/vertex'
        }.freeze

        def resolve_llm_secrets
          log.debug '[llm][providers] resolve_llm_secrets.enter'
          return unless Legion::Settings::Resolver.respond_to?(:resolve_secrets!)

          Legion::Settings::Resolver.resolve_secrets!(Legion::LLM::Settings.current_settings)
          log.debug '[llm][providers] resolve_llm_secrets.exit'
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.resolve_llm_secrets')
        end

        def configure_providers
          log.debug '[llm][providers] configure_providers.enter'
          auto_enable_from_resolved_credentials
          providers_settings.each do |provider, config|
            next unless config_enabled?(config)

            log.debug "[llm][providers] configure_providers applying provider=#{provider}"
            apply_provider_config(provider, config)
          end
          log.debug '[llm][providers] configure_providers.exit'
        end

        def auto_enable_from_resolved_credentials
          log.debug '[llm][providers] auto_enable_from_resolved_credentials.enter'
          providers_settings.each do |provider, config|
            next if config_enabled?(config)

            has_creds = credential_available_for?(provider, config)
            has_creds ||= broker_has_credential?(provider) unless has_creds

            next unless has_creds

            set_config_value(config, :enabled, true)
            log.info "[llm][providers] auto-enabled provider=#{provider} reason=credentials_found"
          end
        end

        def credential_available_for?(provider, config)
          case provider.to_sym
          when :bedrock
            usable_setting?(Legion::LLM::Settings.config_value(config, :bearer_token)) ||
              env_present?('AWS_BEARER_TOKEN_BEDROCK') ||
              (usable_setting?(Legion::LLM::Settings.config_value(config,
                                                                  :api_key)) && usable_setting?(Legion::LLM::Settings.config_value(config, :secret_key)))
          when :anthropic
            usable_setting?(Legion::LLM::Settings.config_value(config, :api_key)) || env_present?('ANTHROPIC_API_KEY')
          when :openai
            usable_setting?(Legion::LLM::Settings.config_value(config, :api_key)) ||
              env_present?('OPENAI_API_KEY') ||
              env_present?('CODEX_API_KEY') ||
              !Call::CodexConfigLoader.read_token.nil?
          when :azure
            Legion::LLM::Settings.config_value(config, :api_base) &&
              (usable_setting?(Legion::LLM::Settings.config_value(config,
                                                                  :api_key)) || usable_setting?(Legion::LLM::Settings.config_value(config, :auth_token)))
          when :ollama
            ollama_running?(config)
          when :vllm
            vllm_running?(config)
          else
            usable_setting?(Legion::LLM::Settings.config_value(config, :api_key))
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.credential_available_for', provider: provider)
          false
        end

        def usable_setting?(value)
          !resolve_credential_value(value).nil?
        end

        def resolve_credential_value(value)
          Call::ClaudeConfigLoader.resolve_setting_reference(value)
        end

        def env_present?(key)
          ENV.fetch(key, nil).to_s.strip != ''
        end

        def ollama_running?(config)
          require 'socket'
          url = Legion::LLM::Settings.config_value(config, :base_url) || 'http://localhost:11434'
          uri = http_uri!(url, default_port: 11_434)
          log.debug "[llm][providers] ollama_running? addr=#{uri.host} port=#{uri.port}"
          Socket.tcp(uri.host, uri.port, connect_timeout: 1).close
          true
        rescue URI::InvalidURIError, ArgumentError => e
          handle_exception(e, level: :error, operation: 'llm.providers.ollama_running.config', base_url: url)
          false
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.ollama_running', base_url: url)
          false
        end

        def vllm_running?(config)
          require 'faraday'
          url = Legion::LLM::Settings.config_value(config, :base_url) || 'http://localhost:8000/v1'
          base = normalize_vllm_base_url(url)
          http_uri!(base, default_port: 8000)
          log.debug "[llm][providers] vllm_running? url=#{base}/health"
          response = Faraday.new(url: base) do |f|
            f.options.timeout = 2
            f.options.open_timeout = 2
            f.adapter Faraday.default_adapter
          end.get('/health')
          response.success?
        rescue URI::InvalidURIError, ArgumentError => e
          handle_exception(e, level: :error, operation: 'llm.providers.vllm_running.config', base_url: url)
          false
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.vllm_running', base_url: url)
          false
        end

        def normalize_vllm_base_url(url)
          base = url.to_s.dup
          base.chop! while base.end_with?('/')
          base = base[0...-3] if base.end_with?('/v1')
          base.empty? ? 'http://localhost:8000' : base
        end

        def http_uri!(url, default_port:)
          require 'uri'

          uri = URI.parse(url.to_s)
          raise ArgumentError, "unsupported URL scheme #{uri.scheme.inspect}" unless %w[http https].include?(uri.scheme)
          raise ArgumentError, 'missing URL host' unless uri.host

          uri.port ||= default_port
          uri
        end

        def apply_provider_config(provider, config)
          case provider.to_sym
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
          resolved_api_key = resolve_credential_value(Legion::LLM::Settings.config_value(config, :api_key))
          resolved_secret_key = resolve_credential_value(Legion::LLM::Settings.config_value(config, :secret_key))
          resolved_session_token = resolve_credential_value(Legion::LLM::Settings.config_value(config, :session_token))
          has_sigv4 = resolved_api_key && resolved_secret_key
          has_bearer = resolve_credential_value(Legion::LLM::Settings.config_value(config, :bearer_token))
          set_config_value(config, :bearer_token, has_bearer) if has_bearer
          set_config_value(config, :api_key, resolved_api_key) if resolved_api_key
          set_config_value(config, :secret_key, resolved_secret_key) if resolved_secret_key
          set_config_value(config, :session_token, resolved_session_token) if resolved_session_token

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

          set_config_value(config, :region, Legion::LLM::Settings.config_value(config, :region) || 'us-east-2')
          return unless has_sigv4 || has_bearer

          auth_mode = has_bearer ? 'bearer token' : 'SigV4'
          log.info "[llm][providers] prepared native bedrock region=#{Legion::LLM::Settings.config_value(config, :region)} auth=#{auth_mode}"
        end

        def configure_anthropic(config)
          api_key = resolve_broker_credential(:anthropic) ||
                    resolve_credential_value(Legion::LLM::Settings.config_value(config, :api_key)) ||
                    ENV.fetch('ANTHROPIC_API_KEY', nil)
          return unless api_key

          set_config_value(config, :api_key, api_key)
          log.info "[llm][providers] prepared native anthropic base_url=#{Legion::LLM::Settings.config_value(config, :base_url).inspect}"
        end

        def configure_openai(config)
          api_key = resolve_broker_credential(:openai) ||
                    resolve_credential_value(Legion::LLM::Settings.config_value(config, :api_key)) ||
                    ENV.fetch('OPENAI_API_KEY', nil) ||
                    ENV.fetch('CODEX_API_KEY', nil)
          return unless api_key

          set_config_value(config, :api_key, api_key)
          log.info "[llm][providers] prepared native openai base_url=#{Legion::LLM::Settings.config_value(config, :base_url).inspect}"
        end

        def configure_gemini(config)
          api_key = resolve_broker_credential(:gemini) ||
                    resolve_credential_value(Legion::LLM::Settings.config_value(config, :api_key)) ||
                    ENV.fetch('GEMINI_API_KEY', nil)
          return unless api_key

          set_config_value(config, :api_key, api_key)
          log.info "[llm][providers] prepared native gemini base_url=#{Legion::LLM::Settings.config_value(config, :base_url).inspect}"
        end

        def configure_azure(config)
          api_base = Legion::LLM::Settings.config_value(config, :api_base)
          api_key = resolve_broker_credential(:azure) || resolve_credential_value(Legion::LLM::Settings.config_value(config, :api_key))
          auth_token = resolve_credential_value(Legion::LLM::Settings.config_value(config, :auth_token))
          return unless api_base && (api_key || auth_token)

          set_config_value(config, :api_key, api_key) if api_key
          set_config_value(config, :auth_token, auth_token) if auth_token
          log.info "[llm][providers] prepared native azure api_base=#{api_base}"
        end

        def configure_ollama(config)
          log.info "[llm][providers] prepared native ollama base_url=#{Legion::LLM::Settings.config_value(config, :base_url).inspect}"
        end

        def configure_vllm(config)
          base_url = Legion::LLM::Settings.config_value(config, :base_url) || 'http://localhost:8000/v1'
          api_key = resolve_credential_value(Legion::LLM::Settings.config_value(config, :api_key))

          set_config_value(config, :base_url, base_url)
          set_config_value(config, :api_key, api_key) if api_key
          log.info "[llm][providers] prepared native vllm base_url=#{base_url.inspect}"
        end

        SAAS_PROVIDERS = %i[bedrock anthropic openai gemini azure].freeze

        def verify_providers
          log.debug '[llm][providers] verify_providers.enter'
          providers_settings.each do |provider, config|
            provider_key = provider.to_sym
            next unless config_enabled?(config)
            next unless SAAS_PROVIDERS.include?(provider_key)

            model = Legion::LLM::Settings.config_value(config, :default_model)
            next unless model

            probe_provider_credentials(provider_key, model, config)
          end

          recover_with_alternative_credentials

          log_available_providers
        end

        def probe_provider_credentials(provider, model, config)
          candidates = collect_credential_candidates(provider, config)

          if candidates.size <= 1
            ok = attempt_provider_call(provider, model)
            set_config_value(config, :enabled, false) unless ok
            return
          end

          working = candidates.find do |creds|
            apply_credential_to_config(provider, config, creds)
            attempt_provider_call(provider, model)
          end

          if working
            apply_credential_to_config(provider, config, working)
            log.info "[llm][providers] health_check ok provider=#{provider} model=#{model} credential=#{working.keys.join(',')}"
          else
            set_config_value(config, :enabled, false)
            log.warn "[llm][providers] disabled provider=#{provider} reason=all_credentials_failed"
          end
        end

        def collect_credential_candidates(provider, config)
          case provider
          when :bedrock
            candidates = []
            resolved_bearer = resolve_credential_value(Legion::LLM::Settings.config_value(config, :bearer_token))
            bearer_env = ENV.fetch('AWS_BEARER_TOKEN_BEDROCK', nil)
            claude_bearer = Call::ClaudeConfigLoader.bedrock_bearer_token
            candidates += [resolved_bearer, bearer_env, claude_bearer].compact.uniq.map { |t| { bearer_token: t } }
            api_key = resolve_credential_value(Legion::LLM::Settings.config_value(config, :api_key))
            secret = resolve_credential_value(Legion::LLM::Settings.config_value(config, :secret_key))
            candidates << { api_key: api_key, secret_key: secret } if api_key && secret
            candidates
          when :anthropic
            [
              resolve_credential_value(Legion::LLM::Settings.config_value(config, :api_key)),
              ENV.fetch('ANTHROPIC_API_KEY', nil)
            ].compact.uniq.map { |k| { api_key: k } }
          when :openai
            keys = [
              resolve_credential_value(Legion::LLM::Settings.config_value(config, :api_key)),
              ENV.fetch('OPENAI_API_KEY', nil),
              ENV.fetch('CODEX_API_KEY', nil),
              Call::CodexConfigLoader.read_token
            ].compact.uniq
            keys.map { |k| { api_key: k } }
          when :gemini
            [
              resolve_credential_value(Legion::LLM::Settings.config_value(config, :api_key)),
              ENV.fetch('GEMINI_API_KEY', nil)
            ].compact.uniq.map { |k| { api_key: k } }
          else
            []
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.collect_credential_candidates', provider: provider)
          []
        end

        def apply_credential_to_config(provider, config, creds)
          case provider
          when :bedrock
            set_config_value(config, :bearer_token, creds[:bearer_token]) if creds[:bearer_token]
            set_config_value(config, :api_key, creds[:api_key])           if creds[:api_key]
            set_config_value(config, :secret_key, creds[:secret_key])     if creds[:secret_key]
          when :anthropic, :openai, :gemini
            set_config_value(config, :api_key, creds[:api_key])
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
          when :unavailable
            log.warn "[llm][providers] health_check unavailable provider=#{provider} reason=native_provider_unregistered"
            false
          else
            log.info "[llm][providers] health_check ok provider=#{provider} model=#{model} elapsed_ms=#{elapsed}"
            true
          end
        rescue StandardError => e
          log.warn "[llm][providers] health_check failed provider=#{provider} error=#{e.class}"
          handle_exception(e, level: :warn, operation: 'llm.providers.attempt_provider_call', provider: provider, model: model)
          false
        end

        def probe_via_model_list(provider, target_model)
          return :unavailable unless Call::Registry.registered?(provider)

          return :ok if target_model.nil?
          return :ok if native_inventory_model_available?(provider, target_model)

          adapter = Call::Registry.for(provider)
          offerings = adapter.respond_to?(:offerings) ? Array(adapter.offerings) : []
          return :ok if offerings.empty?

          :model_missing
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.probe_via_model_list', provider: provider)
          probe_via_chat(provider, target_model)
        end

        def probe_via_chat(provider, model)
          return :unavailable unless Call::Registry.registered?(provider)

          native_inventory_model_available?(provider, model) ? :ok : :model_missing
        end

        def recover_with_alternative_credentials
          log.debug '[llm][providers] recover_with_alternative_credentials.enter'
          recover_openai_with_codex
        end

        def recover_openai_with_codex
          openai_config = Legion::LLM::Settings.config_value(providers_settings, :openai)
          return unless openai_config.is_a?(Hash) && !config_enabled?(openai_config)

          token = Call::CodexConfigLoader.read_token
          return unless token

          log.info '[llm][providers] openai disabled — retrying with codex auth token'
          set_config_value(openai_config, :api_key, token)
          configure_openai(openai_config)
          set_config_value(openai_config, :enabled, true)
          ok = attempt_provider_call(:openai, Legion::LLM::Settings.config_value(openai_config, :default_model))
          set_config_value(openai_config, :enabled, false) unless ok
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.recover_openai_with_codex')
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
          auto_register_lex_llm_providers

          registered = Call::Registry.available
          if registered.any?
            log.info "[llm][providers] native registry registered=#{registered.join(', ')}"
          else
            log.debug '[llm][providers] no native lex-* providers registered'
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.auto_register')
        end

        def log_available_providers
          enabled = providers_settings.select { |_, c| c.is_a?(Hash) && config_enabled?(c) }
          if enabled.empty?
            log.error '[llm][providers] no providers available — all failed health checks or disabled'
          else
            names = enabled.map { |name, c| "#{name}/#{Legion::LLM::Settings.config_value(c, :default_model) || 'auto'}" }
            log.info "[llm][providers] available providers=#{names.join(', ')}"
          end
        end

        def native_inventory_model_available?(provider, target_model)
          return true unless target_model
          return false unless defined?(Legion::LLM::Inventory)

          Legion::LLM::Inventory.offerings(provider_family: provider).any? do |offering|
            model_id = offering[:model].to_s
            model_id.include?(target_model.to_s) || target_model.to_s.include?(model_id) ||
              offering[:canonical_model_alias].to_s == target_model.to_s
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true,
                              operation: 'llm.providers.native_inventory_model_available',
                              provider: provider)
          false
        end

        def auto_register_lex_llm_providers
          return unless load_lex_llm_base

          LEX_LLM_PROVIDER_REQUIRES.each_value { |feature| load_optional_feature(feature) }
          return unless lex_llm_namespace

          providers_config = Legion::LLM::Settings.value(:providers, default: {})
          providers_config.each do |provider_name, provider_config|
            next unless provider_config.is_a?(Hash)
            next if Legion::LLM::Settings.config_value(provider_config, :enabled) == false

            register_instances(provider_name, provider_config)
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.auto_register_lex_llm')
        end

        def register_instances(provider_family, provider_config)
          instances = Legion::LLM::Settings.config_value(provider_config, :instances)

          if instances.is_a?(Hash) && instances.any?
            instances.each do |instance_id, instance_config|
              merged = provider_config.except(:instances, 'instances').merge(instance_config)
              register_single_instance(provider_family, instance_id, merged)
            end
          else
            register_single_instance(provider_family, :default, provider_config)
          end
        end

        def register_single_instance(provider_family, instance_id, config)
          provider_class = resolve_lex_llm_provider_class(provider_family)
          return unless provider_class

          mapped_config = map_settings_to_config_options(provider_family, provider_class, config)
          adapter = Call::LexLLMAdapter.new(provider_family, provider_class, instance_config: mapped_config)
          Call::Registry.register(provider_family, adapter, instance: instance_id)
          Call::Registry.register(:claude, adapter, instance: instance_id) if provider_family.to_sym == :anthropic
          log.info("[llm][providers] registered instance provider=#{provider_family} instance=#{instance_id}")
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: "register_instance.#{provider_family}/#{instance_id}")
        end

        def map_settings_to_config_options(provider_family, provider_class, config)
          options = Array(provider_class.configuration_options)
          mapped = {}
          options.each do |option|
            value = lex_llm_provider_config_value(provider_family, option, config)
            mapped[option] = value unless value.nil?
          end
          mapped
        end

        def resolve_lex_llm_provider_class(provider_family)
          return nil unless defined?(Legion::Extensions::Llm::Provider)

          providers = begin
            Legion::Extensions::Llm::Provider.providers
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.providers.resolve_lex_llm_provider_class')
            {}
          end
          providers[provider_family.to_sym] || providers[provider_family.to_s]
        end

        def load_lex_llm_base
          load_optional_feature('legion/extensions/llm')
          load_optional_feature('legion/extensions/llm/provider') unless lex_llm_namespace
          !lex_llm_namespace.nil?
        end

        def lex_llm_namespace
          return ::Legion::Extensions::Llm if defined?(::Legion::Extensions::Llm::Provider)

          nil
        end

        def load_optional_feature(feature)
          llm_settings = snapshot_llm_settings
          require feature
          restore_llm_settings(llm_settings) if llm_settings_lost?(llm_settings)
          true
        rescue LoadError => e
          handle_exception(e, level: :warn, handled: true,
                              operation: 'llm.providers.optional_feature',
                              feature: feature)
          false
        end

        def snapshot_llm_settings
          settings = nil
          settings = Legion::LLM::Settings.current_settings
          return nil unless settings.is_a?(Hash) && settings.any?

          Marshal.load(Marshal.dump(settings))
        rescue TypeError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.providers.snapshot_marshal_fallback')
          settings&.dup
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true,
                              operation: 'llm.providers.snapshot_llm_settings')
          nil
        end

        def llm_settings_lost?(snapshot)
          return false unless snapshot.is_a?(Hash) && (snapshot.key?(:providers) || snapshot.key?('providers'))

          current = Legion::LLM::Settings.current_settings
          !current.is_a?(Hash) || !(current.key?(:providers) || current.key?('providers'))
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true,
                              operation: 'llm.providers.llm_settings_lost')
          false
        end

        def restore_llm_settings(snapshot)
          Legion::Settings[:llm] = snapshot if snapshot.is_a?(Hash)
          log.warn '[llm][providers] restored LLM settings after optional provider load changed settings backend'
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true,
                              operation: 'llm.providers.restore_llm_settings')
        end

        def lex_llm_provider_ready?(namespace, provider_name, provider_class)
          provider_config = Legion::LLM::Settings.config_value(providers_settings, provider_name.to_sym, {}) || {}
          configure_lex_llm_provider(namespace, provider_name, provider_class, provider_config)

          return true if config_enabled?(provider_config)
          return credential_available_for?(provider_name.to_sym, provider_config) if lex_llm_runtime_probe_required?(provider_name)

          provider_class.configured?(namespace.config)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true,
                              operation: 'llm.providers.lex_llm_provider_ready',
                              provider: provider_name)
          false
        end

        def lex_llm_runtime_probe_required?(provider_name)
          %i[ollama vllm mlx].include?(provider_name.to_sym)
        end

        def configure_lex_llm_provider(namespace, provider_name, provider_class, provider_config)
          Array(provider_class.configuration_options).each do |option|
            next unless namespace.config.respond_to?("#{option}=")

            value = lex_llm_provider_config_value(provider_name, option, provider_config)
            namespace.config.public_send("#{option}=", value) unless value.nil?
          end
        end

        def lex_llm_provider_config_value(provider_name, option, provider_config)
          provider = provider_name.to_sym
          direct = Legion::LLM::Settings.config_value(provider_config, option)
          return resolve_credential_value(direct) if credential_option?(option) && !direct.nil?
          return direct unless direct.nil?

          short_key = option.to_s.delete_prefix("#{provider}_").to_sym
          short_value = Legion::LLM::Settings.config_value(provider_config, short_key)
          return resolve_credential_value(short_value) if credential_option?(option) && !short_value.nil?
          return short_value unless short_value.nil?

          case option.to_s
          when /_api_key\z/
            env_api_key(provider)
          when /_api_base\z/
            api_base = Legion::LLM::Settings.config_value(provider_config, :api_base) ||
                       Legion::LLM::Settings.config_value(provider_config, :base_url) ||
                       Legion::LLM::Settings.config_value(provider_config, :endpoint)
            normalize_lex_llm_api_base(provider, api_base)
          when /_version\z/
            Legion::LLM::Settings.config_value(provider_config, :version)
          end
        end

        def normalize_lex_llm_api_base(provider, value)
          return value if value.nil?
          return value unless %i[openai vllm].include?(provider.to_sym)

          value.to_s.sub(%r{/v1/?\z}, '')
        end

        def credential_option?(option)
          option.to_s.match?(/(_api_key|_token|_secret)\z/)
        end

        def env_api_key(provider)
          env_keys = {
            anthropic: %w[ANTHROPIC_API_KEY],
            gemini:    %w[GEMINI_API_KEY],
            mlx:       %w[MLX_API_KEY],
            openai:    %w[OPENAI_API_KEY CODEX_API_KEY],
            vllm:      %w[VLLM_API_KEY]
          }.fetch(provider, [])

          env_keys.filter_map { |key| ENV.fetch(key, nil).to_s.strip }.find { |value| value != '' }
        end

        def inject_anthropic_cache_control!(opts, provider)
          resolved_provider = (provider || Legion::LLM::Settings.value(:default_provider))&.to_sym
          return unless resolved_provider == :anthropic

          caching_settings = Legion::LLM::Settings.value(:prompt_caching, default: {}) || {}
          return unless Legion::LLM::Settings.config_value(caching_settings, :enabled, true) != false

          min_tokens = Legion::LLM::Settings.config_value(caching_settings, :min_tokens) || 1024
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

          Legion::Identity::Broker.token_for(
            provider_name,
            purpose: 'llm.provider.credential',
            context: { provider: provider_name }
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: "llm.providers.broker_resolve.#{provider_name}")
          nil
        end

        def resolve_broker_aws_credentials
          return nil unless defined?(Legion::Identity::Broker)

          renewer = Legion::Identity::Broker.renewer_for(:aws)
          return renewer.provider.current_credentials if renewer&.provider.respond_to?(:current_credentials)

          nil
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.broker_resolve.aws')
          nil
        end

        def broker_has_credential?(provider)
          return false unless defined?(Legion::Identity::Broker)

          case provider
          when :bedrock
            renewer = Legion::Identity::Broker.renewer_for(:aws)
            renewer&.provider.respond_to?(:current_credentials) && !renewer.provider.current_credentials.nil?
          else
            !Legion::Identity::Broker.token_for(
              provider,
              purpose: 'llm.provider.credential_available',
              context: { provider: provider }
            ).nil?
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'llm.providers.broker_credential_available', provider: provider)
          false
        end

        def try_register_native_provider(name, ext_const, runner_const)
          log.debug "[llm][providers] try_register_native_provider name=#{name} ext=#{ext_const}"
          return unless constant_defined_path?(ext_const) && constant_defined_path?(runner_const)

          klass = constant_get_path(runner_const)
          yield klass
          log.debug "[llm][providers] registered native provider name=#{name}"
        end

        def constant_defined_path?(path)
          names = path.to_s.split('::')
          names.shift if names.first == ''
          owner = Object
          names.all? do |name|
            return false unless owner.const_defined?(name, false)

            owner = owner.const_get(name, false)
          end
        end

        def constant_get_path(path)
          path.to_s.split('::').reject(&:empty?).reduce(Object) do |owner, name|
            owner.const_get(name, false)
          end
        end

        def providers_settings
          Legion::LLM::Settings.value(:providers, default: {})
        end

        def config_enabled?(config)
          config.is_a?(Hash) && Legion::LLM::Settings.config_value(config, :enabled) == true
        end

        def set_config_value(config, key, value)
          if config.respond_to?(:key?) && config.key?(key.to_s)
            config[key.to_s] = value
          else
            config[key] = value
          end
        end
      end
    end
  end
end
