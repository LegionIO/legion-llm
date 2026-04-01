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
          budget:           budget_defaults,
          confidence:       confidence_defaults,
          discovery:        discovery_defaults,
          gateway:          gateway_defaults,
          daemon:           daemon_defaults,
          prompt_caching:   prompt_caching_defaults,
          arbitrage:        arbitrage_defaults,
          batch:            batch_defaults,
          scheduling:       scheduling_defaults,
          rag:              rag_defaults,
          embedding:        embedding_defaults,
          conversation:     conversation_defaults,
          telemetry:        telemetry_defaults,
          context_curation: context_curation_defaults,
          debate:           debate_defaults,
          provider_layer:   provider_layer_defaults
        }
      end

      def self.confidence_defaults
        {
          bands: {
            low:       0.3,
            medium:    0.5,
            high:      0.7,
            very_high: 0.9
          }
        }
      end

      def self.daemon_defaults
        {
          url:     'http://127.0.0.1:4567',
          enabled: true
        }
      end

      def self.prompt_caching_defaults
        {
          enabled:             false,
          min_tokens:          1024,
          scope:               'ephemeral',
          cache_system_prompt: true,
          cache_tools:         true,
          cache_conversation:  true,
          sort_tools:          true,
          response_cache:      {
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
            pipeline_enabled:  true,
            max_attempts:      3,
            quality_threshold: 50
          },
          rules:          [],
          tier_mappings:  []
        }
      end

      def self.budget_defaults
        {
          session_max_tokens:  nil,
          session_warn_tokens: nil,
          daily_max_tokens:    nil
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

      def self.embedding_defaults
        {
          dimension:         1024,
          enforce_dimension: true,
          provider_fallback: %w[ollama bedrock openai],
          provider_models:   {
            ollama:  'mxbai-embed-large',
            bedrock: 'amazon.titan-embed-text-v2:0',
            openai:  'text-embedding-3-small'
          },
          ollama_preferred:  %w[mxbai-embed-large nomic-embed-text bge-large snowflake-arctic-embed]
        }
      end

      def self.telemetry_defaults
        {
          pipeline_spans: true
        }
      end

      def self.context_curation_defaults
        {
          enabled:               true,
          mode:                  'heuristic',
          llm_assisted:          false,
          llm_model:             nil,
          tool_result_max_chars: 2000,
          thinking_eviction:     true,
          exchange_folding:      true,
          superseded_eviction:   true,
          dedup_enabled:         true,
          dedup_threshold:       0.85,
          target_context_tokens: 40_000
        }
      end

      def self.conversation_defaults
        {
          summarize_threshold: 50_000,
          target_tokens:       20_000,
          preserve_recent:     10,
          auto_compact:        true
        }
      end

      def self.provider_layer_defaults
        {
          mode:                 'ruby_llm',
          native_providers:     %w[claude bedrock],
          fallback_to_ruby_llm: true
        }
      end

      def self.debate_defaults
        {
          enabled:                  false,
          gaia_auto_trigger:        false,
          default_rounds:           1,
          max_rounds:               3,
          advocate_model:           nil,
          challenger_model:         nil,
          judge_model:              nil,
          model_selection_strategy: 'rotate'
        }
      end

      def self.providers
        {
          bedrock:   {
            enabled:       false,
            default_model: 'us.anthropic.claude-sonnet-4-6',
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
            default_model: 'qwen3.5:latest',
            base_url:      'http://localhost:11434'
          }
        }
      end
    end
  end
end

begin
  Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default) if Legion.const_defined?('Settings', false)
rescue StandardError => e
  if Legion.const_defined?('Logging', false) && Legion::Logging.respond_to?(:fatal)
    Legion::Logging.fatal(e.message)
    Legion::Logging.fatal(e.backtrace)
  else
    puts e.message
    puts e.backtrace
  end
end
