# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/settings'

module Legion
  module LLM
    module Settings
      extend Legion::Logging::Helper

      CLIENT_TOOL_PASSTHROUGH_BLACKLIST_DEFAULT = [
        'sudo', 'visudo', 'su', 'legion', 'legionio', 'legionio do', 'legionio/legion',
        'computer_use_session', 'computer_use_control', 'computer_use_session_info',
        'computer_use_session_message', 'plugin__aithena__recall', 'plugin__aithena__remember',
        'plugin__aithena__skill_search', 'plugin__aithena__skill_feedback', 'plugin__aithena__memory_stats',
        'plugin__cron__create', 'plugin__cron__list', 'plugin__cron__get', 'plugin__cron__update',
        'plugin__cron__delete', 'plugin__cron__get_history', 'plugin__cron__run_now', 'plugin__cron__stop'
      ].freeze
      CLIENT_TOOL_PASSTHROUGH_WHITELIST_DEFAULT = [].freeze

      def self.default
        model_override = ENV.fetch('ANTHROPIC_MODEL', nil)
        {
          enabled:                        true,
          connected:                      false,
          pipeline_enabled:               true,
          pipeline_async_post_steps:      true,
          context_window:                 250_000,
          max_output_tokens:              16_384,
          max_tool_rounds:                200,
          max_tool_calls_per_turn:        100,
          tool_result_max_dispatch_chars: 10_000,
          default_model:                  model_override,
          default_temperature:            0.9,
          default_provider:               nil,
          system_baseline:                system_baseline_default,
          fleet:                          fleet_defaults,
          routing:                        routing_defaults,
          budget:                         budget_defaults,
          confidence:                     confidence_defaults,
          discovery:                      discovery_defaults,
          daemon:                         daemon_defaults,
          prompt_caching:                 prompt_caching_defaults,
          arbitrage:                      arbitrage_defaults,
          batch:                          batch_defaults,
          scheduling:                     scheduling_defaults,
          rag:                            rag_defaults,
          rag_guard:                      rag_guard_defaults,
          gaia:                           gaia_defaults,
          knowledge_capture:              knowledge_capture_defaults,
          embedding:                      embedding_defaults,
          conversation:                   conversation_defaults,
          telemetry:                      telemetry_defaults,
          metering:                       metering_defaults,
          context_curation:               context_curation_defaults,
          debate:                         debate_defaults,
          provider_layer:                 provider_layer_defaults,
          tool_trigger:                   tool_trigger_defaults,
          api:                            api_defaults,
          compliance:                     compliance_defaults,
          skills:                         skills_defaults,
          claude_cli:                     claude_cli_defaults,
          fallback:                       fallback_defaults,
          structured_output:              structured_output_defaults
        }
      end

      def self.register_defaults!
        log.debug '[llm][settings] action=register_defaults'
        Legion::Settings.register_library(:llm, default)
      end

      def self.validate!(settings)
        if settings.is_a?(Hash) && (settings.key?(:gateway) || settings.key?('gateway'))
          raise ArgumentError,
                'llm.gateway has been removed; configure provider instances instead'
        end

        routing = settings.is_a?(Hash) ? (settings[:routing] || settings['routing'] || {}) : {}
        if routing.is_a?(Hash) && (routing.key?(:use_fleet) || routing.key?('use_fleet'))
          raise ArgumentError,
                'routing.use_fleet has been removed; configure fleet.dispatch.enabled instead'
        end

        settings
      end

      def self.claude_cli_defaults
        {
          settings_path: '~/.claude/settings.json',
          config_path:   '~/.claude.json'
        }
      end

      def self.system_baseline_default
        <<~PROMPT.strip
          You are Legion, an agentic AI partner running on the LegionIO framework.

          LegionIO is a governed, production-oriented cognitive task and orchestration platform.
          Your role is to help the user accomplish real work quickly, directly, and safely.

          Core behavior:
          - Honor user intent and constraints.
          - Prefer execution over prompt ceremony: do the task when possible, don't just describe it.
          - Be concise by default; expand only when the user asks for depth.
          - Be transparent: never claim you ran something you did not run, and never hide uncertainty.
          - Minimize blast radius: make the smallest effective change and preserve existing behavior unless asked otherwise.
          - Do not YOLO risky actions. For destructive, irreversible, security-sensitive, or high-impact actions, pause and get explicit confirmation.
          - When risk or ambiguity is high, ask focused clarifying questions before acting.
          - Validate outcomes when practical, and report what changed and why.
          - Prefer solving work directly in-session; only produce handoff artifacts (including prompts for other AI tools) when the user explicitly asks for that format.

          Trust model:
          - Trust is earned through reliable outcomes, clarity, and safe execution.
          - Speed matters, but never at the expense of integrity or user trust.

          Tool use:
          - There is no tool call limit per turn. You may make as many tool calls as needed to complete the task.
          - Do not stop mid-task claiming you hit a limit. Continue until the work is done or you need user input.
        PROMPT
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
          enabled:             true,
          min_tokens:          1024,
          scope:               'ephemeral',
          cache_system_prompt: true,
          cache_tools:         true,
          cache_conversation:  true,
          sort_tools:          true,
          response_cache:      {
            enabled:               true,
            ttl_seconds:           300,
            spool_dir:             '~/.legionio/data/spool/llm_responses',
            spool_threshold_bytes: 8 * 1024 * 1024
          }
        }
      end

      def self.discovery_defaults
        {
          enabled:                true,
          refresh_seconds:        60,
          memory_floor_mb:        2048,
          memory_overhead_factor: 1.4
        }
      end

      def self.fleet_defaults
        {
          dispatch:  {
            enabled:                false,
            exchange:               'llm.fleet',
            routing_style:          :shared_lane,
            mandatory:              true,
            publisher_confirm:      true,
            spool:                  false,
            timeout_seconds:        30,
            timeouts:               { chat: 30, stream: 30, embed: 10, image: 60, default: 30 },
            require_auth:           nil,
            token_ttl_seconds:      180,
            reply_queue_expires_ms: 60_000,
            reply_queue_prefix:     'llm.fleet.reply',
            request_ttl_ms:         120_000
          },
          auth:      {
            require_signed_token:   true,
            issuer:                 'legion-llm',
            audience:               'lex-llm-fleet-worker',
            algorithm:              'HS256',
            accepted_issuers:       ['legion-llm'],
            max_clock_skew_seconds: 30
          },
          responder: {
            enabled:                    false,
            require_auth:               nil,
            require_policy:             false,
            require_idempotency:        true,
            idempotency_ttl_seconds:    600,
            accepted_protocol_version:  2,
            mandatory:                  false,
            publisher_confirm:          false,
            publish_confirm_timeout_ms: 500,
            spool:                      false
          }
        }
      end

      def self.routing_defaults
        {
          enabled:        true,
          tier_priority:  %w[local direct fleet cloud frontier],
          default_intent: { privacy: 'normal', capability: 'moderate', cost: 'normal' },
          tiers:          {
            local:    { provider: 'ollama' },
            fleet:    {
              queue:           'llm.fleet',
              routing_style:   :shared_lane,
              timeout_seconds: 30,
              timeouts:        { embed: 10, chat: 30, generate: 30, default: 30 }
            },
            cloud:    { providers: %w[bedrock azure gemini] },
            frontier: { providers: %w[anthropic openai] }
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
            quality_threshold: 0
          },
          rules:          [],
          tier_mappings:  []
        }
      end

      def self.budget_defaults
        {
          session_max_tokens:  nil,
          session_warn_tokens: nil,
          daily_max_tokens:    nil,
          session_usd:         0.0
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
          enabled:                       false,
          full_limit:                    5,
          compact_limit:                 3,
          min_confidence:                0.92,
          utilization_compact_threshold: 0.7,
          utilization_skip_threshold:    0.9,
          conversation_history_enabled:  false,
          trivial_max_chars:             20,
          trivial_patterns:              %w[hello hi hey ping pong test ok okay yes no thanks thank],
          exclude_source_agents:         %w[teams-api-ingest unknown teams-entity-extractor legion-interlink]
        }
      end

      def self.rag_guard_defaults
        {
          threshold:        0.7,
          block_on_failure: false,
          evaluators:       %i[faithfulness rag_relevancy]
        }
      end

      def self.gaia_defaults
        {
          advisory_enabled: false
        }
      end

      def self.knowledge_capture_defaults
        {
          enabled:              false,
          writeback_enabled:    false,
          local_ingest_enabled: false
        }
      end

      def self.embedding_defaults
        {
          dimension:                    1024,
          enforce_dimension:            true,
          provider_fallback:            %w[ollama bedrock openai],
          provider_models:              {
            bedrock:   'amazon.titan-embed-text-v2:0',
            anthropic: nil,
            openai:    'text-embedding-3-small',
            gemini:    'text-embedding-004',
            azure:     'text-embedding-3-small',
            ollama:    'mxbai-embed-large'
          },
          ollama_preferred:             %w[mxbai-embed-large nomic-embed-text bge-large snowflake-arctic-embed],
          ollama_context_chars:         {
            'mxbai-embed-large'      => 1400,
            'bge-large'              => 1400,
            'snowflake-arctic-embed' => 1400,
            'nomic-embed-text'       => 24_000
          },
          ollama_default_context_chars: 1400,
          prefix_registry:              {
            'nomic-embed-text'  => { document: 'search_document: ', query: 'search_query: ' },
            'mxbai-embed-large' => { query: 'Represent this sentence for searching relevant passages: ' }
          }
        }
      end

      def self.telemetry_defaults
        {
          pipeline_spans: true
        }
      end

      def self.metering_defaults
        {
          spool: {
            max_events:        10_000,
            flush_batch_sleep: 0.0
          }
        }
      end

      def self.context_curation_defaults
        {
          enabled:                 true,
          mode:                    'heuristic',
          llm_assisted:            false,
          llm_model:               nil,
          tool_result_max_chars:   10_000,
          thinking_eviction:       false,
          exchange_folding:        false,
          superseded_eviction:     true,
          dedup_enabled:           true,
          dedup_threshold:         0.85,
          target_context_tokens:   60_000,
          archive_dropped_turns:   true,
          archive_preserve_recent: 10
        }
      end

      def self.conversation_defaults
        {
          summarize_threshold: 90_000,
          target_tokens:       60_000,
          preserve_recent:     10,
          auto_compact:        true
        }
      end

      def self.provider_layer_defaults
        {
          mode:             'auto',
          native_providers: %w[
            ollama vllm anthropic openai gemini mlx
            bedrock azure_foundry vertex
          ]
        }
      end

      def self.tool_trigger_defaults
        {
          scan_depth:                        10,
          tool_limit:                        25,
          local_tool_limit:                  50,
          client_tool_passthrough:           true,
          client_tool_passthrough_whitelist: CLIENT_TOOL_PASSTHROUGH_WHITELIST_DEFAULT.dup,
          client_tool_passthrough_blacklist: CLIENT_TOOL_PASSTHROUGH_BLACKLIST_DEFAULT.dup
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

      def self.api_defaults
        {
          use_namespaces: true,
          auth:           {
            enabled:      false,
            api_keys:     [],
            pass_through: false
          }
        }
      end

      def self.skills_defaults
        {
          enabled:           true,
          auto_inject:       true,
          on_demand:         true,
          max_active_skills: 1,
          directories:       ['.legion/skills', '~/.legionio/skills'],
          auto_discover:     { claude: false, codex: false },
          enabled_skills:    [],
          disabled_skills:   []
        }
      end

      def self.fallback_defaults
        {
          allow_local: true
        }
      end

      def self.structured_output_defaults
        {
          retry_on_parse_failure: false,
          max_retries:            2
        }
      end

      def self.compliance_defaults
        {
          classification_scan:   false,
          encrypt_audit:         false,
          encrypt_metering:      false,
          phi_block_cloud:       false,
          cloud_providers:       %w[bedrock anthropic openai gemini azure],
          redact_pii:            false,
          redaction_placeholder: '[REDACTED]',
          strict_hipaa:          false,
          standalone_email_pii:  false,
          default_level:         :public,
          audit_max_messages:    20
        }
      end
    end
  end
end

Legion::LLM::Settings.register_defaults!

begin
  Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default) if Legion.const_defined?('Settings', false)
rescue StandardError => e
  Legion::LLM::Settings.handle_exception(e, level: :fatal, operation: :merge_settings)
end
