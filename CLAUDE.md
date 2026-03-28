# legion-llm

**Repository Level 3 Documentation**
- **Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## Purpose

Core LegionIO gem providing LLM capabilities to all extensions. Wraps ruby_llm to provide a consistent interface for chat, embeddings, tool use, and agents across multiple providers (Bedrock, Anthropic, OpenAI, Gemini, Ollama). Includes a dynamic weighted routing engine that dispatches requests across local, fleet, and cloud tiers based on caller intent, priority rules, time schedules, cost multipliers, and real-time provider health.

**GitHub**: https://github.com/LegionIO/legion-llm
**Version**: 0.5.12
**License**: Apache-2.0

## Architecture

### Startup Sequence

```
Legion::LLM.start
  ├── 1. Read settings from Legion::Settings[:llm]
  ├── 2. For each enabled provider:
  │     ├── Resolve credentials from Vault (if vault_path set)
  │     └── Configure RubyLLM provider
  ├── 3. Run discovery (if Ollama enabled): warm model + system memory caches
  ├── 4. Auto-detect default model from first enabled provider
  └── 5. Ping provider (if default_model + default_provider set): send test request, log latency
```

### Module Structure

```
Legion::LLM (lib/legion/llm.rb)
├── EscalationExhausted # Raised when all escalation attempts are exhausted
├── DaemonDeniedError   # Raised when daemon returns HTTP 403
├── DaemonRateLimitedError # Raised when daemon returns HTTP 429
├── LLMError / AuthError / RateLimitError / ContextOverflow / ProviderError / ProviderDown / UnsupportedCapability / PipelineError # Typed error hierarchy with retryable?
├── ConversationStore   # In-memory LRU (256 conversations) + optional DB persistence via Sequel
├── Settings         # Default config, provider settings, routing defaults, discovery defaults
├── Providers        # Provider configuration and Vault credential resolution (includes Azure `configure_azure`)
├── DaemonClient     # HTTP routing to LegionIO daemon with 30s health cache
├── ResponseCache    # Async response delivery via memcached with spool overflow
├── Compressor       # Deterministic prompt compression (3 levels, code-block-aware)
├── Discovery        # Runtime introspection for local model availability and system resources
│   ├── Ollama       # Queries Ollama /api/tags for pulled models (TTL-cached)
│   └── System       # Queries OS memory: macOS (vm_stat/sysctl), Linux (/proc/meminfo)
├── QualityChecker   # Response quality heuristics (empty, too_short, repetition, json_parse, json_expected) + pluggable callable
├── EscalationHistory # Mixin for response objects: escalation_history, escalated?, final_resolution, escalation_chain
├── Embeddings       # Structured embedding wrapper: generate, generate_batch, default_model
├── ShadowEval       # Parallel shadow evaluation on cheaper models with sampling
├── StructuredOutput # JSON schema enforcement with native response_format and prompt fallback
├── Router           # Dynamic weighted routing engine
│   ├── Resolution   # Value object: tier, provider, model, rule name, metadata, compress_level
│   ├── Rule         # Routing rule: intent matching, schedule windows, constraints
│   ├── HealthTracker # Circuit breaker, latency rolling window, pluggable signal handlers
│   └── EscalationChain # Ordered fallback resolution chain with max_attempts cap (pads last resolution if chain is short)
├── Pipeline         # 18-step request/response pipeline (feature-flagged)
│   ├── Request      # Data.define struct for unified request representation
│   ├── Response     # Data.define struct for unified response representation
│   ├── Profile      # Caller-derived profiles (external/gaia/system) for step skipping
│   ├── Tracing      # Distributed trace_id, span_id, exchange_id generation
│   ├── Timeline     # Ordered event recording with participant tracking
│   ├── Executor     # 18-step pipeline skeleton with profile-aware execution
│   ├── Steps/
│   │   └── Metering # Metering event builder (absorbed from lex-llm-gateway)
│   └── Executor#call_stream # Streaming variant: pre-provider steps, yield chunks, post-provider steps
├── CostEstimator    # Model cost estimation with fuzzy pricing (absorbed from lex-llm-gateway)
├── Fleet            # Fleet RPC dispatch (absorbed from lex-llm-gateway)
│   ├── Dispatcher   # Fleet dispatch with timeout and availability checks
│   ├── Handler      # Fleet request handler for GPU worker nodes
│   └── ReplyDispatcher # Correlation-based reply routing for fleet RPC
└── Helpers::LLM     # Extension helper mixin (llm_chat, llm_embed, llm_session, compress:)
```

### Routing Architecture

Three-tier dispatch model. Local-first avoids unnecessary network hops; fleet offloads to shared hardware via Transport; cloud is the fallback for frontier models.

```
┌─────────────────────────────────────────────────────────┐
│              Legion::LLM Router (per-node)               │
│                                                          │
│  Tier 1: LOCAL  → Ollama on this machine (direct HTTP)   │
│          Zero network overhead, no Transport              │
│                                                          │
│  Tier 2: FLEET  → Ollama on Mac Studios / GPU servers    │
│          Via lex-llm-gateway RPC over AMQP               │
│                                                          │
│  Tier 3: CLOUD  → Bedrock / Anthropic / OpenAI / Gemini │
│          Existing provider API calls                     │
└─────────────────────────────────────────────────────────┘
```

### Routing Resolution Flow

```
1. Caller passes intent: { privacy: :strict, capability: :basic }
2. Router merges with default_intent (fills missing dimensions)
3. Load rules from settings, filter by:
   a. Intent match (all `when` conditions must match)
   b. Schedule window (valid_from/valid_until, hours, days)
   c. Constraints (e.g., never_cloud strips cloud-tier rules)
   d. Discovery (Ollama model pulled? Model fits in available RAM?)
   e. Tier availability (is Ollama running? is Transport loaded?)
4. Score remaining candidates:
   effective_priority = rule.priority
                      + health_tracker.adjustment(provider)
                      + (1.0 - cost_multiplier) * 10
5. Return Resolution for highest-scoring candidate
```

### Gateway Integration (lex-llm-gateway)

Gateway delegation removed in v0.4.1. `chat`, `embed`, and `structured` route directly — no `begin/rescue LoadError` block, no `gateway_loaded?` check. The pipeline (enabled by default since v0.4.8) handles metering and fleet dispatch natively. The `_direct` variants still exist as the canonical non-pipeline path for `chat_direct`, `embed_direct`, `structured_direct`.

### Integration with LegionIO

- **Service**: `setup_llm` called between data and supervision in startup sequence
- **Extensions**: `llm_required?` method on extension module, checked at load time
- **Helpers**: `Legion::Extensions::Helpers::LLM` auto-loaded when gem is present
- **Readiness**: Registers as `:llm` in `Legion::Readiness`
- **Shutdown**: `Legion::LLM.shutdown` called during service shutdown
- **Gateway**: `lex-llm-gateway` auto-loaded if present; provides metering and fleet RPC

## Dependencies

| Gem | Purpose |
|-----|---------|
| `ruby_llm` (>= 1.0) | Multi-provider LLM client |
| `tzinfo` (>= 2.0) | IANA timezone conversion for schedule windows |
| `legion-logging` | Logging |
| `legion-settings` | Configuration |
| `lex-llm-gateway` (removed) | No longer auto-loaded; pipeline handles metering and fleet dispatch natively |

## Key Interfaces

```ruby
# Core
Legion::LLM.start                    # Configure providers, set defaults
Legion::LLM.shutdown                 # Cleanup
Legion::LLM.started?                 # -> Boolean
Legion::LLM.settings                 # -> Hash

# One-shot convenience (daemon-first, direct fallback)
Legion::LLM.ask(message, model:, provider:)                 # -> Hash with :content key; raises DaemonDeniedError/DaemonRateLimitedError

# Chat (delegates to gateway when loaded, otherwise direct)
Legion::LLM.chat(message: 'hello', model:, provider:)       # Gateway-metered if available
Legion::LLM.chat(intent: { privacy: :strict })              # Intent-based routing
Legion::LLM.chat(tier: :cloud, model: 'claude-sonnet-4-6')  # Explicit tier override
Legion::LLM.chat_direct(message:, model:, provider:)        # Bypass gateway (no metering)
Legion::LLM.embed(text, model:)                             # Embeddings (gateway-metered)
Legion::LLM.embed_direct(text, model:)                      # Bypass gateway
Legion::LLM.structured(messages:, schema:)                  # Structured (gateway-metered)
Legion::LLM.structured_direct(messages:, schema:)           # Bypass gateway
Legion::LLM.agent(AgentClass)                               # Agent instance

# Compressor
Legion::LLM::Compressor.compress(text, level: 1)                  # -> String (deterministic)
Legion::LLM::Compressor.stopwords_for_level(2)                    # -> Array of words

# Router
Legion::LLM::Router.resolve(intent:, tier:, model:, provider:)  # -> Resolution or nil
Legion::LLM::Router.health_tracker                               # -> HealthTracker
Legion::LLM::Router.routing_enabled?                             # -> Boolean
Legion::LLM::Router.reset!                                       # Clear cached state

# HealthTracker
tracker = Legion::LLM::Router.health_tracker
tracker.report(provider: :anthropic, signal: :error, value: 1)   # Feed signal
tracker.report(provider: :ollama, signal: :latency, value: 1200) # Feed latency
tracker.adjustment(:anthropic)                                    # -> Integer (priority offset)
tracker.circuit_state(:anthropic)                                 # -> :closed/:open/:half_open
tracker.register_handler(:gpu_utilization) { |data| ... }         # Extend with new signals

# Escalation
Legion::LLM.chat(message:, escalate: true, max_escalations: 3, quality_check:) # Escalating chat — raises EscalationExhausted if all attempts fail
Legion::LLM::EscalationExhausted                                                # raised when all escalation attempts are exhausted
Legion::LLM::Router.resolve_chain(intent:, tier:, max_escalations:)            # -> EscalationChain
Legion::LLM::QualityChecker.check(response, quality_threshold: 50, json_expected: false, quality_check: nil) # -> QualityResult
```

## Settings

Settings read from `Legion::Settings[:llm]`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | Boolean | `true` | Enable LLM support |
| `connected` | Boolean | `false` | Set to true after successful start |
| `pipeline_enabled` | Boolean | `true` | Enable 18-step pipeline for chat() dispatch (enabled by default since v0.4.8) |
| `default_model` | String | `nil` | Default model ID (auto-detected if nil) |
| `default_provider` | Symbol | `nil` | Default provider (auto-detected if nil) |
| `providers` | Hash | See below | Per-provider configuration |
| `routing` | Hash | See below | Dynamic routing engine configuration |
| `discovery` | Hash | See below | Ollama model discovery and system memory settings |

### Provider Settings

Each provider has: `enabled`, `api_key`, `vault_path`, plus provider-specific keys.

Vault credential resolution: When `vault_path` is set and Legion::Crypt::Vault is connected, credentials are fetched from Vault at startup. Keys map to provider-specific fields automatically.

Bedrock supports two auth modes:
- **SigV4** (default): `api_key` + `secret_key` (+ optional `session_token`)
- **Bearer token**: `bearer_token` for AWS Identity Center/SSO. When set, `bedrock_bearer_auth.rb` is required lazily to monkey-patch RubyLLM's Bedrock provider.

### Auto-Detection Priority

When no defaults are configured, the first enabled provider is used:

1. Bedrock -> `us.anthropic.claude-sonnet-4-6-v1`
2. Anthropic -> `claude-sonnet-4-6`
3. OpenAI -> `gpt-4o`
4. Gemini -> `gemini-2.0-flash`
5. Azure -> (endpoint-specific, from `api_base`)
6. Ollama -> `llama3`

### Routing Settings

Nested under `Legion::Settings[:llm][:routing]`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | Boolean | `false` | Enable routing (opt-in) |
| `default_intent` | Hash | `{ privacy: 'normal', capability: 'moderate', cost: 'normal' }` | Defaults merged into every intent |
| `tiers.local` | Hash | `{ provider: 'ollama' }` | Local tier config |
| `tiers.fleet` | Hash | `{ queue: 'llm.inference', timeout_seconds: 30 }` | Fleet tier config |
| `tiers.cloud` | Hash | `{ providers: ['bedrock', 'anthropic'] }` | Cloud tier config |
| `health.window_seconds` | Integer | `300` | Rolling window for latency tracking |
| `health.circuit_breaker.failure_threshold` | Integer | `3` | Consecutive failures before circuit opens |
| `health.circuit_breaker.cooldown_seconds` | Integer | `60` | Seconds before circuit transitions to half_open |
| `health.latency_penalty_threshold_ms` | Integer | `5000` | Latency above this triggers priority penalty |
| `health.budget.daily_limit_usd` | Float | `nil` | Daily cloud spend limit (future) |
| `health.budget.monthly_limit_usd` | Float | `nil` | Monthly cloud spend limit (future) |
| `rules` | Array | `[]` | Routing rules (see below) |
| `escalation.enabled` | Boolean | `false` | Enable model escalation on retry |
| `escalation.max_attempts` | Integer | `3` | Max escalation attempts per call |
| `escalation.quality_threshold` | Integer | `50` | Min response character length |

### Routing Rules

Each rule is a hash with:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | String | Yes | Unique rule identifier |
| `when` | Hash | Yes | Intent conditions to match (`privacy`, `capability`, `cost`) |
| `then` | Hash | No | Target: `{ tier:, provider:, model: }` |
| `priority` | Integer | No (default 0) | Higher wins when multiple rules match |
| `constraint` | String | No | Hard constraint (e.g., `never_cloud`) |
| `fallback` | String | No | Fallback tier if primary is unavailable |
| `cost_multiplier` | Float | No (default 1.0) | Lower = cheaper = routing bonus |
| `schedule` | Hash | No | Time-based activation window |
| `note` | String | No | Human-readable note |

### Intent Dimensions

| Dimension | Values | Default | Effect |
|-----------|--------|---------|--------|
| `privacy` | `:strict`, `:normal` | `:normal` | `:strict` -> never cloud (via `never_cloud` constraint rules) |
| `capability` | `:basic`, `:moderate`, `:reasoning` | `:moderate` | Higher prefers larger/cloud models |
| `cost` | `:minimize`, `:normal` | `:normal` | `:minimize` prefers local/fleet |

### Schedule Windows

Rules can include a `schedule` hash for time-based activation:

| Field | Format | Example |
|-------|--------|---------|
| `valid_from` | ISO 8601 | `"2026-03-15T00:00:00"` |
| `valid_until` | ISO 8601 | `"2026-03-29T23:59:59"` |
| `hours` | Array of "HH:MM-HH:MM" | `["00:00-06:00", "18:00-23:59"]` |
| `days` | Array of day names | `["monday", "tuesday"]` |
| `timezone` | IANA timezone | `"America/Chicago"` (converts `now` via TZInfo before evaluating hours/days) |

All fields optional. Omit any to mean "always active."

### Discovery Settings

Nested under `Legion::Settings[:llm][:discovery]`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | Boolean | `true` | Master switch for discovery checks |
| `refresh_seconds` | Integer | `60` | TTL for both discovery caches |
| `memory_floor_mb` | Integer | `2048` | Minimum free MB to reserve for OS |

Discovery is lazy TTL-cached: data refreshes on the next `Router.resolve` call after TTL expires. At startup, caches are warmed if Ollama is enabled. When disabled, all discovery checks are bypassed (permissive).

### HealthTracker

In-memory signal consumer with pluggable handlers. Adjusts effective priorities at runtime.

**Built-in signals:** `:error` (circuit breaker), `:success` (circuit recovery), `:latency` (rolling window penalty), `:quality_failure` (half-weight circuit breaker, 6 failures to trip vs 3 for hard errors)

**Circuit breaker states:**
- `:closed` (normal, adjustment = 0)
- `:open` (after `failure_threshold` consecutive errors, adjustment = -50)
- `:half_open` (after `cooldown_seconds`, tries one request, adjustment = -25)

**Latency penalty:** `-10` per multiple above `LATENCY_THRESHOLD_MS` (5000ms), capped at `-50`

**Extensible:** Call `register_handler(:signal_name) { |data| ... }` to add new signal types. Signal providers (like lex-metering) call `report()` with `defined?(Legion::LLM::Router)` guard.

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/llm.rb` | Entry point: start, shutdown, chat (with routing), embed, agent |
| `lib/legion/llm/settings.rb` | Default settings including routing_defaults, auto-merge into Legion::Settings |
| `lib/legion/llm/providers.rb` | Provider config, Vault resolution, RubyLLM configuration |
| `lib/legion/llm/bedrock_bearer_auth.rb` | Monkey-patch for Bedrock Bearer Token auth — required lazily |
| `lib/legion/llm/claude_config_loader.rb` | Import Claude CLI config from `~/.claude/settings.json` and `~/.claude.json` |
| `lib/legion/llm/response_cache.rb` | Async response delivery via memcached with spool overflow at 8MB |
| `lib/legion/llm/daemon_client.rb` | HTTP routing to LegionIO daemon with health caching (30s TTL) |
| `lib/legion/llm/compressor.rb` | Deterministic prompt compression: 3 levels, code-block-aware, stopword removal |
| `lib/legion/llm/router.rb` | Router module: resolve, health_tracker, select_candidates pipeline |
| `lib/legion/llm/router/resolution.rb` | Value object: tier, provider, model, rule, metadata, compress_level |
| `lib/legion/llm/router/rule.rb` | Rule class: from_hash, matches_intent?, within_schedule?, to_resolution |
| `lib/legion/llm/router/health_tracker.rb` | HealthTracker: circuit breaker, latency window, pluggable signal handlers |
| `lib/legion/llm/discovery/ollama.rb` | Ollama /api/tags discovery with TTL cache |
| `lib/legion/llm/discovery/system.rb` | OS memory introspection (macOS + Linux) with TTL cache |
| `lib/legion/llm/embeddings.rb` | Embeddings module: generate, generate_batch, default_model |
| `lib/legion/llm/shadow_eval.rb` | Shadow evaluation: enabled?, should_sample?, evaluate, compare |
| `lib/legion/llm/structured_output.rb` | JSON schema enforcement with native response_format and prompt fallback |
| `lib/legion/llm/errors.rb` | Typed error hierarchy: LLMError base + AuthError, RateLimitError, ContextOverflow, ProviderError, ProviderDown, UnsupportedCapability, PipelineError |
| `lib/legion/llm/conversation_store.rb` | ConversationStore: in-memory LRU (256 slots) + optional Sequel DB persistence + spool fallback |
| `lib/legion/llm/version.rb` | Version constant |
| `lib/legion/llm/quality_checker.rb` | QualityChecker module with QualityResult struct |
| `lib/legion/llm/escalation_history.rb` | EscalationHistory mixin: `escalation_history`, `escalated?`, `final_resolution`, `escalation_chain` |
| `lib/legion/llm/router/escalation_chain.rb` | EscalationChain value object |
| `lib/legion/llm/transport/exchanges/escalation.rb` | AMQP exchange for escalation events |
| `lib/legion/llm/transport/messages/escalation_event.rb` | AMQP message for escalation events |
| `lib/legion/llm/pipeline.rb` | Pipeline module: requires all pipeline components |
| `lib/legion/llm/pipeline/request.rb` | Pipeline::Request Data.define struct with .build and .from_chat_args |
| `lib/legion/llm/pipeline/response.rb` | Pipeline::Response Data.define struct with .build, .from_ruby_llm, #with |
| `lib/legion/llm/pipeline/profile.rb` | Pipeline::Profile: caller-derived profiles for step skipping |
| `lib/legion/llm/pipeline/tracing.rb` | Pipeline::Tracing: trace_id, span_id, exchange_id generation |
| `lib/legion/llm/pipeline/timeline.rb` | Pipeline::Timeline: ordered event recording |
| `lib/legion/llm/pipeline/executor.rb` | Pipeline::Executor: 18-step skeleton with profile-aware execution |
| `lib/legion/llm/pipeline/steps/metering.rb` | Pipeline::Steps::Metering: metering event builder |
| `lib/legion/llm/pipeline/steps/rag_context.rb` | Pipeline::Steps::RagContext: context strategy selection and Apollo retrieval (step 8) |
| `lib/legion/llm/pipeline/steps/rag_guard.rb` | Pipeline::Steps::RagGuard: faithfulness check against retrieved RAG context |
| `lib/legion/llm/pipeline/enrichment_injector.rb` | Pipeline::EnrichmentInjector: converts RAG/GAIA enrichments into system prompt |
| `lib/legion/llm/cost_estimator.rb` | CostEstimator: model cost estimation with fuzzy pricing |
| `lib/legion/llm/fleet.rb` | Fleet module: requires dispatcher, handler, reply_dispatcher |
| `lib/legion/llm/fleet/dispatcher.rb` | Fleet::Dispatcher: fleet RPC dispatch |
| `lib/legion/llm/fleet/handler.rb` | Fleet::Handler: fleet request handler |
| `lib/legion/llm/fleet/reply_dispatcher.rb` | Fleet::ReplyDispatcher: correlation-based reply routing |
| `lib/legion/llm/helpers/llm.rb` | Extension helper mixin: llm_chat (with compress:, escalate:, max_escalations:, quality_check:), llm_embed, llm_session |
| `spec/legion/llm_spec.rb` | Tests: settings, lifecycle, providers, auto-config |
| `spec/legion/llm/integration_spec.rb` | Tests: routing integration with chat() |
| `spec/legion/llm/router_spec.rb` | Tests: Router.resolve, priority selection, constraints, health |
| `spec/legion/llm/router/resolution_spec.rb` | Tests: Resolution value object |
| `spec/legion/llm/router/rule_spec.rb` | Tests: Rule intent matching, from_hash, to_resolution |
| `spec/legion/llm/router/rule_schedule_spec.rb` | Tests: Rule schedule evaluation |
| `spec/legion/llm/router/health_tracker_spec.rb` | Tests: circuit breaker, latency, signal handlers |
| `spec/legion/llm/router/settings_spec.rb` | Tests: routing defaults in settings |
| `spec/legion/llm/compressor_spec.rb` | Tests: compression levels, code-block protection, determinism |
| `spec/legion/llm/helpers/llm_spec.rb` | Tests: helper mixin with compress integration |
| `spec/legion/llm/discovery/ollama_spec.rb` | Tests: Ollama model discovery, TTL, error handling |
| `spec/legion/llm/discovery/system_spec.rb` | Tests: System memory introspection |
| `spec/legion/llm/discovery/router_integration_spec.rb` | Tests: Router discovery filtering |
| `spec/legion/llm/discovery/startup_spec.rb` | Tests: Startup discovery warmup |
| `spec/legion/llm/discovery/settings_spec.rb` | Tests: Discovery settings defaults |
| `spec/legion/llm/quality_checker_spec.rb` | QualityChecker tests |
| `spec/legion/llm/escalation_history_spec.rb` | EscalationHistory tests |
| `spec/legion/llm/escalation_integration_spec.rb` | chat() escalation loop tests |
| `spec/legion/llm/router/escalation_chain_spec.rb` | EscalationChain tests |
| `spec/legion/llm/router/resolve_chain_spec.rb` | Router.resolve_chain tests |
| `spec/legion/llm/transport/escalation_spec.rb` | Transport tests |
| `spec/legion/llm/embeddings_spec.rb` | Embeddings tests |
| `spec/legion/llm/shadow_eval_spec.rb` | ShadowEval tests |
| `spec/legion/llm/structured_output_spec.rb` | StructuredOutput tests |
| `spec/legion/llm/errors_spec.rb` | Tests: typed error hierarchy, retryable? predicate |
| `spec/legion/llm/conversation_store_spec.rb` | Tests: LRU eviction, append, messages, DB fallback |
| `spec/legion/llm/pipeline/executor_stream_spec.rb` | Tests: call_stream chunk yielding, pre/post steps |
| `spec/legion/llm/pipeline/streaming_integration_spec.rb` | Tests: streaming end-to-end with ConversationStore |
| `spec/legion/llm/gateway_integration_spec.rb` | Tests: gateway teardown — verifies no delegation |
| `spec/legion/llm/cost_estimator_spec.rb` | Tests: cost estimation, fuzzy matching, pricing table |
| `spec/legion/llm/pipeline/request_spec.rb` | Tests: Request struct builder, legacy adapter |
| `spec/legion/llm/pipeline/response_spec.rb` | Tests: Response struct builder, RubyLLM adapter, #with |
| `spec/legion/llm/pipeline/profile_spec.rb` | Tests: Profile derivation and step skipping |
| `spec/legion/llm/pipeline/tracing_spec.rb` | Tests: Tracing init, exchange_id generation |
| `spec/legion/llm/pipeline/timeline_spec.rb` | Tests: Timeline event recording, participants |
| `spec/legion/llm/pipeline/executor_spec.rb` | Tests: Executor pipeline execution, profile skipping |
| `spec/legion/llm/pipeline/integration_spec.rb` | Tests: Pipeline integration with chat() dispatch |
| `spec/legion/llm/pipeline/steps/metering_spec.rb` | Tests: Metering event building |
| `spec/legion/llm/fleet/dispatcher_spec.rb` | Tests: Fleet dispatch, availability, timeout |
| `spec/legion/llm/fleet/handler_spec.rb` | Tests: Fleet handler, auth, response building |
| `spec/legion/llm/pipeline/steps/rag_context_spec.rb` | Tests: RAG context strategy selection, Apollo retrieval, graceful degradation |
| `spec/legion/llm/pipeline/steps/rag_guard_spec.rb` | Tests: RAG faithfulness checking |
| `spec/legion/llm/pipeline/enrichment_injector_spec.rb` | Tests: enrichment injection into system prompt |
| `spec/legion/llm/pipeline/rag_gas_integration_spec.rb` | Tests: RAG/GAS full cycle integration |
| `spec/spec_helper.rb` | Stubbed Legion::Logging and Legion::Settings for testing |

## Extension Integration

Extensions declare LLM dependency via `llm_required?`:

```ruby
module Legion::Extensions::MyLex
  def self.llm_required?
    true
  end
end
```

Helper methods available in runners when gem is loaded:

```ruby
# Direct (no routing)
llm_chat(message, model:, provider:, tools:, instructions:)
llm_embed(text, model:)
llm_session(model:, provider:)

# With routing
llm_chat(message, intent: { privacy: :strict, capability: :basic })
llm_chat(message, tier: :cloud, model: 'claude-sonnet-4-6')
llm_session(intent: { capability: :reasoning })
```

## Vault Integration

Provider credentials are resolved by the universal `Legion::Settings::Resolver` (in `legion-settings`), not by legion-llm itself. Use `vault://` and `env://` URI references directly in settings values:

```json
{
  "llm": {
    "providers": {
      "bedrock": {
        "enabled": true,
        "bearer_token": ["vault://secret/data/llm/bedrock#bearer_token", "env://AWS_BEARER_TOKEN"],
        "region": "us-east-2"
      },
      "anthropic": {
        "enabled": true,
        "api_key": "env://ANTHROPIC_API_KEY"
      }
    }
  }
}
```

By the time `Legion::LLM.start` runs, all `vault://` and `env://` references have already been resolved to plain strings by `Legion::Settings.resolve_secrets!` (called in the boot sequence after `Legion::Crypt.start`).

The legacy `vault_path` per-provider setting was removed in v0.3.1.

## Testing

Tests run without the full LegionIO stack. `spec/spec_helper.rb` stubs `Legion::Logging` and `Legion::Settings` with in-memory implementations. Each test resets settings to defaults via `before(:each)`.

```bash
bundle exec rspec    # 882 examples, 0 failures
bundle exec rubocop  # 0 offenses
```

## Design Documents

- `docs/work/completed/2026-03-14-llm-dynamic-routing-design.md` — Full design (approved)
- `docs/work/completed/2026-03-14-llm-dynamic-routing-implementation.md` — Implementation plan
- `docs/work/completed/2026-03-16-llm-escalation-design.md` — Model escalation design (approved)
- `docs/work/completed/2026-03-16-llm-escalation-implementation.md` — Escalation implementation plan

## Future (Not Yet Built)

- **Advanced signals**: Budget tracking, GPU utilization monitoring, per-tenant spend limits
- **Fleet auto-scaling**: Dynamic worker pool sizing based on queue depth and latency

---

**Maintained By**: Matthew Iverson (@Esity)
