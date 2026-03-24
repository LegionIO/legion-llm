# frozen_string_literal: true

module Legion
  module LLM
    module Settings
      def self.default
        model_override = ENV.fetch('ANTHROPIC_MODEL', nil)
        {
          enabled:          true,
          connected:        false,
          pipeline_enabled: true,
          default_model:    model_override,
          default_provider: nil,
          providers:        providers,
          routing:          routing_defaults,
          discovery:        discovery_defaults,
          gateway:          gateway_defaults,
          daemon:           daemon_defaults,
          prompt_caching:   prompt_caching_defaults,
          arbitrage:        arbitrage_defaults,
          batch:            batch_defaults,
          scheduling:       scheduling_defaults,
          rag:              rag_defaults
        }
      end

      def self.daemon_defaults
        {
          url:     nil,
          enabled: false
        }
      end

      def self.prompt_caching_defaults
        {
          enabled:        true,
          min_tokens:     1024,
          response_cache: {
            enabled:     true,
            ttl_seconds: 300
          }
        }
      end

      def self.discovery_defaults
        {
          enabled:         true,
          refresh_seconds: 60,
          memory_floor_mb: 2048
        }
      end

      def self.routing_defaults
        {
          enabled:        false,
          default_intent: { privacy: 'normal', capability: 'moderate', cost: 'normal' },
          tiers:          {
            local: { provider: 'ollama' },
            fleet: { queue: 'llm.inference', timeout_seconds: 30 },
            cloud: { providers: %w[bedrock anthropic] }
          },
          health:         {
            window_seconds:               300,
            circuit_breaker:              { failure_threshold: 3, cooldown_seconds: 60 },
            latency_penalty_threshold_ms: 5000,
            budget:                       { daily_limit_usd: nil, monthly_limit_usd: nil }
          },
          escalation:     {
            enabled:           false,
            max_attempts:      3,
            quality_threshold: 50
          },
          rules:          []
        }
      end

      def self.gateway_defaults
        {
          enabled:            false,
          endpoint:           nil,
          api_key:            nil,
          timeout_seconds:    30,
          model_policy:       {},
          headers:            {},
          fallback_to_direct: true
        }
      end

      def self.arbitrage_defaults
        {
          enabled:            false,
          prefer_cheapest:    true,
          quality_floor:      0.7,
          cost_table_refresh: 86_400,
          cost_table:         {}
        }
      end

      def self.batch_defaults
        {
          enabled:          false,
          window_seconds:   300,
          max_batch_size:   100,
          eligible_intents: %w[batch background low_priority]
        }
      end

      def self.scheduling_defaults
        {
          enabled:         false,
          peak_hours_utc:  '14-22',
          defer_intents:   %w[batch background],
          max_defer_hours: 8
        }
      end

      def self.rag_defaults
        {
          enabled:                       true,
          full_limit:                    10,
          compact_limit:                 5,
          min_confidence:                0.5,
          utilization_compact_threshold: 0.7,
          utilization_skip_threshold:    0.9,
          trivial_max_chars:             20,
          trivial_patterns:              %w[hello hi hey ping pong test ok okay yes no thanks thank]
        }
      end

      def self.providers
        {
          bedrock:   {
            enabled:       false,
            default_model: 'us.anthropic.claude-sonnet-4-6-v1',
            api_key:       nil,
            secret_key:    nil,
            session_token: nil,
            bearer_token:  'env://AWS_BEARER_TOKEN_BEDROCK',
            region:        'us-east-2'
          },
          anthropic: {
            enabled:       false,
            default_model: 'claude-sonnet-4-6',
            api_key:       'env://ANTHROPIC_API_KEY'
          },
          openai:    {
            enabled:       false,
            default_model: 'gpt-4o',
            api_key:       ['env://OPENAI_API_KEY', 'env://CODEX_API_KEY']
          },
          gemini:    {
            enabled:       false,
            default_model: 'gemini-2.0-flash',
            api_key:       'env://GEMINI_API_KEY'
          },
          azure:     {
            enabled:       false,
            default_model: nil,
            api_base:      nil,
            api_key:       nil,
            auth_token:    nil
          },
          ollama:    {
            enabled:       false,
            default_model: 'llama3',
            base_url:      'http://localhost:11434'
          }
        }
      end
    end
  end
end

begin
  Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default) if Legion.const_defined?('Settings')
rescue StandardError => e
  if Legion.const_defined?('Logging') && Legion::Logging.respond_to?(:fatal)
    Legion::Logging.fatal(e.message)
    Legion::Logging.fatal(e.backtrace)
  else
    puts e.message
    puts e.backtrace
  end
end
