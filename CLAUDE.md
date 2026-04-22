# legion-llm

**Repository Level 3 Documentation**
- **Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## Purpose

Core LegionIO gem providing LLM capabilities to all extensions. Wraps ruby_llm to provide a consistent interface for chat, embeddings, tool use, and agents across multiple providers (Bedrock, Anthropic, OpenAI, Gemini, Ollama). Includes a dynamic weighted routing engine that dispatches requests across local, fleet, and cloud tiers based on caller intent, priority rules, time schedules, cost multipliers, and real-time provider health.

**GitHub**: https://github.com/LegionIO/legion-llm
**Version**: 0.8.0
**License**: Apache-2.0

## Architecture

### Startup Sequence

```
Legion::LLM.start
  ├── 1.  Call::ClaudeConfigLoader.load     (import ~/.claude/settings.json if present)
  ├── 2.  Call::CodexConfigLoader.load      (import ~/.codex/auth.json bearer token if present)
  ├── 3.  Call::Providers.setup             (configure enabled providers, resolve credentials)
  ├── 4.  Discovery.run                     (warm Ollama model + system memory caches)
  ├── 5.  Discovery.detect_embedding_capability  (find best embedding provider/model)
  ├── 6.  Config.set_defaults               (auto-detect default model/provider if not set)
  ├── 7.  Hooks.install_defaults            (install metering + budget guard hooks)
  ├── 8.  Tools::Interceptor.load_defaults  (register built-in tool interceptors)
  ├── 9.  Skills.start                      (load skill definitions from disk + external discovery)
  ├── 10. Transport.load_all                (load AMQP exchanges + messages if Transport available)
  ├── 11. Fleet.load_transport              (load fleet exchange + messages)
  ├── 12. Audit.load_transport              (load audit exchange + messages)
  ├── 13. Metering.load_transport           (load metering exchange + messages)
  └── 14. API.register_routes               (register /v1/ and /api/llm/ routes with Legion::API)
```

### Module Structure

```
Legion::LLM (lib/legion/llm.rb)          # Thin facade — delegates to Inference, Call, Discovery
├── Patches                              # Monkey-patches for upstream gems
│   └── RubyLLMParallelTools            # Parallel tool execution patch for RubyLLM
├── Errors                               # Typed error hierarchy (LLMError base + subtypes, retryable?)
│   └── EscalationExhausted / DaemonDeniedError / DaemonRateLimitedError / AuthError /
│       RateLimitError / ContextOverflow / ProviderError / ProviderDown /
│       UnsupportedCapability / InferenceError / TokenBudgetExceeded
├── Types                                # Immutable Data.define structs per schema spec
│   ├── Message      # id, role, content, tool_calls, tokens, conversation_id, task_id
│   ├── ToolCall     # id, name, arguments, source, status, duration_ms, result
│   ├── ContentBlock # type, text, data, tool_use/result fields, cache_control
│   └── Chunk        # Streaming delta: content_delta / thinking_delta / tool_call_delta / done
├── Config                               # Settings and defaults
│   └── Settings     # Default config, provider settings, routing defaults, API auth defaults
├── Call                                 # Provider call layer (replaces bare Providers/NativeDispatch)
│   ├── Providers        # Provider configuration, auto-detect, verify
│   ├── Registry         # Thread-safe lex-* provider extension registry (was ProviderRegistry)
│   ├── Dispatch         # Native provider dispatch to registered lex-* extensions (was NativeDispatch)
│   ├── Embeddings       # generate, generate_batch, default_model, fallback chain
│   ├── StructuredOutput # JSON schema enforcement with native response_format and prompt fallback
│   ├── DaemonClient     # HTTP routing to LegionIO daemon with 30s health cache
│   ├── BedrockAuth      # Monkey-patch for Bedrock Bearer Token auth (required lazily)
│   ├── ClaudeConfigLoader # Import Claude CLI config from ~/.claude/settings.json
│   └── CodexConfigLoader  # Import OpenAI bearer token from ~/.codex/auth.json
├── Context                              # Prompt and conversation context management
│   ├── Compressor   # Deterministic prompt compression (3 levels, code-block-aware)
│   └── Curator      # Async conversation curation: strip thinking, distill tools, fold resolved exchanges
├── Discovery                            # Runtime introspection
│   ├── Ollama       # Queries Ollama /api/tags for pulled models (TTL-cached)
│   └── System       # Queries OS memory: macOS (vm_stat/sysctl), Linux (/proc/meminfo)
├── Quality                              # Response quality evaluation
│   ├── Checker      # Quality heuristics (empty, too_short, repetition, json_parse) + pluggable (was QualityChecker)
│   ├── ShadowEval   # Parallel shadow evaluation on cheaper models with sampling
│   └── Confidence/
│       ├── Score    # Immutable ConfidenceScore value object (score, band, source, signals)
│       └── Scorer   # Computes ConfidenceScore from logprobs, heuristics, or caller-provided value
├── Metering                             # Unified token/cost accounting and AMQP event emission
│   ├── Usage        # Immutable Usage struct (input_tokens, output_tokens, cache tokens)
│   ├── Pricing      # Model cost estimation with fuzzy matching (was CostEstimator)
│   ├── Recorder     # Per-request in-memory cost accumulator (was CostTracker)
│   └── Tokens       # Thread-safe per-session token budget accumulator (was TokenTracker)
├── Inference                            # 18-step request/response pipeline (was Pipeline)
│   ├── Request      # Data.define struct for unified request representation
│   ├── Response     # Data.define struct for unified response representation
│   ├── Profile      # Caller-derived profiles (external/gaia/system) for step skipping
│   ├── Tracing      # Distributed trace_id, span_id, exchange_id generation
│   ├── Timeline     # Ordered event recording with participant tracking
│   ├── Executor     # 18-step skeleton with profile-aware execution and call_stream
│   ├── Conversation # In-memory LRU (256 slots) + optional Sequel DB persistence (was ConversationStore)
│   ├── Prompt       # Clean dispatch API: dispatch, request, summarize, extract, decide
│   ├── ToolAdapter  # Wraps Tools::Base for RubyLLM sessions (McpToolAdapter kept as alias)
│   ├── ToolDispatcher # Routes tool calls: MCP client / LEX runner / RubyLLM builtin
│   ├── AuditPublisher # Publishes audit events to llm.audit exchange
│   ├── EnrichmentInjector # Converts RAG/GAIA enrichments into system prompt
│   ├── GaiaCaller   # Gaia-specific chat dispatch with phase/tick tracing
│   ├── McpToolAdapter # Backward-compat alias for ToolAdapter
│   └── Steps/       # All 18+ pipeline step modules
│       ├── Metering, Billing, TokenBudget, PromptCache, Classification, Rbac
│       ├── GaiaAdvisory, TierAssigner, TriggerMatch, ToolDiscovery, McpDiscovery, RagContext
│       ├── SkillInjector, ToolCalls, ConfidenceScoring
│       ├── PostResponse, KnowledgeCapture, RagGuard, Debate, SpanAnnotator
│       ├── StickyHelpers, StickyRunners, ToolHistory, StickyPersist
│       └── (all steps are profile-skippable via GAIA_SKIP / SYSTEM_SKIP / QUICK_REPLY_SKIP)
├── Router                               # Dynamic weighted routing engine
│   ├── Resolution   # Value object: tier, provider, model, rule name, metadata, compress_level
│   ├── Rule         # Routing rule: intent matching, schedule windows, constraints
│   ├── HealthTracker # Circuit breaker, latency rolling window, pluggable signal handlers
│   ├── EscalationChain # Ordered fallback resolution chain with max_attempts cap
│   ├── Arbitrage    # Cost-aware model selection when no rules match
│   ├── GatewayInterceptor # Policy-based cloud-tier interception (model allowlist per risk tier)
│   └── Escalation/
│       ├── History  # EscalationHistory mixin (was EscalationHistory at top level)
│       └── Tracker  # Escalation event tracking
├── Fleet                                # Fleet RPC dispatch over AMQP
│   ├── Dispatcher   # Fleet RPC dispatch with routing key building, per-type timeouts
│   ├── Handler      # Fleet request handler for GPU worker nodes
│   └── ReplyDispatcher # Correlation-based reply routing, fulfill_return, fulfill_nack
├── Metering (module-level)              # emit(event), flush_spool — AMQP publish to llm.metering
├── Audit                                # emit_prompt, emit_tools, emit_skill — AMQP publish to llm.audit
├── Transport                            # Centralized AMQP message classes
│   ├── Message      # LLM base message: context propagation, LLM headers, envelope stripping
│   ├── Exchanges/
│   │   ├── Fleet    # llm.request topic exchange
│   │   ├── Metering # llm.metering topic exchange
│   │   ├── Audit    # llm.audit topic exchange
│   │   └── Escalation # llm.escalation topic exchange
│   └── Messages/
│       ├── FleetRequest / FleetResponse / FleetError
│       ├── MeteringEvent
│       ├── AuditEvent / PromptEvent / ToolEvent / SkillEvent
│       └── EscalationEvent
├── API                                  # Sinatra route modules
│   ├── Auth         # Config-driven Bearer/x-api-key auth for /v1/ routes
│   ├── Native/
│   │   ├── Inference  # POST /api/llm/inference
│   │   ├── Chat       # POST /api/llm/chat
│   │   ├── Providers  # GET /api/llm/providers, GET /api/llm/providers/:name
│   │   └── Helpers    # Shared: parse_request_body, json_response, emit_sse_event, etc.
│   ├── OpenAI/
│   │   ├── ChatCompletions # POST /v1/chat/completions (streaming via data: [DONE])
│   │   ├── Models          # GET /v1/models, GET /v1/models/:id
│   │   └── Embeddings      # POST /v1/embeddings
│   ├── Anthropic/
│   │   └── Messages        # POST /v1/messages (streaming via message_start/stop events)
│   └── Translators/
│       ├── OpenAIRequest / OpenAIResponse
│       └── AnthropicRequest / AnthropicResponse
├── Scheduling                           # Deferred execution
│   ├── Batch        # Non-urgent request batching with priority queue and auto-flush
│   └── OffPeak      # Peak-hour deferral (delegates to Scheduling)
├── Tools                                # Tool call layer
│   ├── Confidence   # 4-tier degrading confidence storage (was OverrideConfidence)
│   ├── Dispatcher   # Routes tool calls to MCP/LEX/RubyLLM
│   ├── Interceptor  # Extensible pre-dispatch intercept registry
│   ├── Adapter      # Wraps lex-* extension tool as RubyLLM::Tool
│   └── Interceptors/
│       └── PythonVenv # Redirects python3/pip3 tool calls to isolated venv
├── Hooks                                # before/after chat interceptor registry
│   ├── RagGuard     # Post-generation RAG faithfulness check
│   ├── ResponseGuard # Central post-generation safety dispatch
│   ├── BudgetGuard  # Blocks calls when session budget is exceeded
│   ├── CostTracking # After-chat hook: records token usage via Metering::Recorder
│   ├── Metering     # After-chat hook: publishes metering events to AMQP
│   ├── Reciprocity  # Records social exchange events via Social::Client
│   └── Reflection   # Extracts knowledge from conversations (decisions, patterns, facts)
├── Cache                                # Application-level response caching
│   └── Response     # Async delivery via memcached with spool overflow at 8MB (was ResponseCache)
├── Skills                               # Daemon-side skill execution subsystem
│   ├── Base         # DSL base class (skill_name, trigger, steps, follows)
│   ├── Registry     # Thread-safe skill registry with trigger index and cycle detection
│   ├── Settings     # Skill-specific settings merge into Legion::Settings
│   ├── DiskLoader   # Loads skill definitions from directories
│   ├── ExternalDiscovery # Auto-discovers skill directories from Claude/Codex configs
│   ├── Errors       # Skill-specific error types
│   ├── StepResult   # Immutable step execution result
│   └── SkillRunResult # Immutable overall skill run result
└── Helper           # Extension helper mixin (llm_chat, llm_embed, llm_session, compress:)
                     # lib/legion/llm/helpers/llm.rb is a backward-compat shim that includes Helper

Note: Backward-compat aliases live in lib/legion/llm/compat.rb (const_missing-based, emit deprecation warnings):
  Pipeline → Inference, ConversationStore → Inference::Conversation,
  NativeDispatch → Call::Dispatch, ProviderRegistry → Call::Registry,
  CostEstimator → Metering::Pricing, CostTracker → Metering::Recorder,
  TokenTracker → Metering::Tokens, QualityChecker → Quality::Checker,
  Compressor → Context::Compressor, ResponseCache → Cache::Response,
  DaemonClient → Call::DaemonClient, ShadowEval → Quality::ShadowEval
```

### Routing Architecture

Five-tier dispatch model. Local-first avoids unnecessary network hops; fleet offloads to shared hardware via Transport; openai_compat routes to user-configured gateways; cloud handles managed cloud providers; frontier is the fallback for direct frontier model providers.

```
┌──────────────────────────────────────────────────────────────┐
│               Legion::LLM Router (per-node)                   │
│                                                               │
│  Tier 1: LOCAL        → Ollama on this machine (direct HTTP)  │
│          Zero network overhead, no Transport                   │
│                                                               │
│  Tier 2: FLEET        → Ollama on Mac Studios / GPU servers   │
│          Via Fleet::Dispatcher RPC over AMQP                  │
│                                                               │
│  Tier 3: OPENAI_COMPAT → User-configured OpenAI-spec gateways│
│          UAIS, Kong AI, custom endpoints                      │
│                                                               │
│  Tier 4: CLOUD        → Bedrock, Azure, Gemini/Vertex AI     │
│          Managed cloud provider API calls                     │
│                                                               │
│  Tier 5: FRONTIER     → Anthropic, OpenAI direct              │
│          Direct API calls to frontier model providers          │
└──────────────────────────────────────────────────────────────┘
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

### Gateway Status

The `lex-llm-gateway` extension is dead. All gateway functionality (metering, fleet dispatch, audit) was absorbed into legion-llm core in the v0.7 restructure. Fleet dispatch is now built-in via `Fleet::Dispatcher` (RPC over AMQP). Metering and audit publish directly to their respective AMQP exchanges. There is no external gateway dependency.

### Integration with LegionIO

- **Service**: `setup_llm` called between data and supervision in startup sequence
- **Extensions**: `llm_required?` method on extension module, checked at load time
- **Helpers**: `Legion::Extensions::Helpers::LLM` auto-loaded when gem is present
- **Readiness**: Registers as `:llm` in `Legion::Readiness`
- **Shutdown**: `Legion::LLM.shutdown` called during service shutdown

### Types

Immutable `Data.define` structs used across the pipeline and API layers. All types live under `Legion::LLM::Types`.

| Type | Fields | Factory Methods |
|------|--------|-----------------|
| `Message` | id, parent_id, role, content, tool_calls, tool_call_id, name, status, version, timestamp, seq, provider, model, input_tokens, output_tokens, conversation_id, task_id | `.build(**kwargs)`, `.from_hash(hash)`, `.wrap(input)` |
| `ToolCall` | id, exchange_id, name, arguments, source, status, duration_ms, result, error, started_at, finished_at | `.build(**kwargs)`, `.from_hash(hash)`, `#with_result(result:, status:, ...)`, `#to_audit_hash` |
| `ContentBlock` | type, text, data, source_type, media_type, detail, name, file_id, id, input, tool_use_id, is_error, source, start_index, end_index, code, message, cache_control | `.text(content)`, `.thinking(content)`, `.tool_use(id:, name:, input:)`, `.tool_result(tool_use_id:, content:)`, `.image(data:, media_type:)`, `.from_hash(hash)` |
| `Chunk` | request_id, conversation_id, exchange_id, index, type, content_block_index, delta, tool_call, usage, stop_reason, tracing, timestamp | `.content_delta(delta:, request_id:, ...)`, `.done(request_id:, ...)`, `#content?`, `#done?` |

Chunk types: `:content_delta`, `:thinking_delta`, `:tool_call_delta`, `:usage`, `:done`, `:error`.

### /v1/ API Compatibility Routes

legion-llm exposes OpenAI-compatible and Anthropic-compatible API routes under `/v1/`. These routes are registered with the main `Legion::API` Sinatra app at startup. All `/v1/*` routes are protected by config-driven auth (Bearer token or `x-api-key` header) when `settings[:api][:auth][:enabled]` is true.

**OpenAI-compatible:**

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/chat/completions` | Chat completions (streaming via `data: [DONE]`) |
| `GET` | `/v1/models` | List available models (from Discovery + configured providers) |
| `GET` | `/v1/models/:id` | Get single model details |
| `POST` | `/v1/embeddings` | Generate embeddings |

**Anthropic-compatible:**

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/messages` | Messages API (streaming via `message_start`/`content_block_delta`/`message_stop` SSE events) |

**Native (Legion-specific):**

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/llm/inference` | Full pipeline inference |
| `POST` | `/api/llm/chat` | Chat endpoint |
| `GET` | `/api/llm/providers` | List configured providers |
| `GET` | `/api/llm/providers/:name` | Provider details |

All compatibility routes normalize requests through `API::Translators` (OpenAIRequest, OpenAIResponse, AnthropicRequest, AnthropicResponse) and dispatch through the Inference pipeline via `Inference::Executor`.

## Dependencies

| Gem | Purpose |
|-----|---------|
| `ruby_llm` (>= 1.0) | Multi-provider LLM client |
| `tzinfo` (>= 2.0) | IANA timezone conversion for schedule windows |
| `legion-logging` | Logging |
| `legion-settings` | Configuration |

## Key Interfaces

```ruby
# Core
Legion::LLM.start                    # Configure providers, set defaults
Legion::LLM.shutdown                 # Cleanup
Legion::LLM.started?                 # -> Boolean
Legion::LLM.settings                 # -> Hash

# One-shot convenience (daemon-first, direct fallback)
Legion::LLM.ask(message, model:, provider:)                 # -> Hash with :content key; raises DaemonDeniedError/DaemonRateLimitedError

# Chat (routes through Inference pipeline by default)
Legion::LLM.chat(message: 'hello', model:, provider:)       # Through Inference pipeline (metered)
Legion::LLM.chat(intent: { privacy: :strict })              # Intent-based routing
Legion::LLM.chat(tier: :cloud, model: 'claude-sonnet-4-6')  # Explicit tier override
Legion::LLM.chat_direct(message:, model:, provider:)        # Bypass pipeline (no metering/steps)
Legion::LLM.embed(text, model:)                             # Embeddings
Legion::LLM.embed_direct(text, model:)                      # Embeddings (no telemetry wrapper)
Legion::LLM.embed_batch(texts, model:)                      # Batch embeddings
Legion::LLM.structured(messages:, schema:)                  # Structured output (JSON schema)
Legion::LLM.structured_direct(messages:, schema:)           # Structured output (no telemetry wrapper)
Legion::LLM.agent(AgentClass)                               # Agent instance

# Compressor (was Compressor, now Context::Compressor; Compressor still works via compat alias)
Legion::LLM::Context::Compressor.compress(text, level: 1)         # -> String (deterministic)
Legion::LLM::Context::Compressor.stopwords_for_level(2)           # -> Array of words

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
Legion::LLM::Quality::Checker.check(response, quality_threshold: 50, json_expected: false, quality_check: nil) # -> QualityResult

# Metering
Legion::LLM::Metering.emit(event_hash)                        # -> :published | :spooled | :dropped
Legion::LLM::Metering.flush_spool                             # -> Integer (count flushed)

# Audit
Legion::LLM::Audit.emit_prompt(event_hash)                    # -> :published | :dropped
Legion::LLM::Audit.emit_tools(event_hash)                     # -> :published | :dropped

# Fleet Dispatcher
Legion::LLM::Fleet::Dispatcher.dispatch(model:, messages:, **) # Old signature (backwards compat)
Legion::LLM::Fleet::Dispatcher.dispatch(request:, message_context:, routing_key:, **) # New signature
Legion::LLM::Fleet::Dispatcher.build_routing_key(provider:, request_type:, model:)    # -> String
Legion::LLM::Fleet::Dispatcher.fleet_available?                # -> Boolean
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
| `tier_priority` | Array | `%w[local fleet openai_compat cloud frontier]` | Ordered tier preference for routing |
| `tiers.local` | Hash | `{ provider: 'ollama' }` | Local tier config |
| `tiers.fleet` | Hash | `{ queue: 'llm.inference', timeout_seconds: 30 }` | Fleet tier config |
| `tiers.openai_compat` | Hash | `{ gateways: [] }` | User-configured OpenAI-compatible gateways |
| `tiers.cloud` | Hash | `{ providers: ['bedrock', 'azure', 'gemini'] }` | Managed cloud provider API calls |
| `tiers.frontier` | Hash | `{ providers: ['anthropic', 'openai'] }` | Direct API frontier providers |
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
| `privacy` | `:strict`, `:normal` | `:normal` | `:strict` -> never external (via `never_external` constraint rules, blocks cloud + frontier + openai_compat) |
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
| `lib/legion/llm.rb` | Thin facade: start, shutdown, delegates to Inference/Call/Discovery |
| `lib/legion/llm/patches/ruby_llm_parallel_tools.rb` | Monkey-patch for RubyLLM parallel tool execution |
| `lib/legion/llm/compat.rb` | Backward-compat aliases via const_missing with deprecation warnings |
| `lib/legion/llm/errors.rb` | Typed error hierarchy: LLMError base + all subtypes, retryable? predicate |
| `lib/legion/llm/version.rb` | Version constant |
| `lib/legion/llm/types.rb` | Types entry point: requires all type files |
| `lib/legion/llm/types/message.rb` | Message Data.define struct with build, from_hash, text, to_provider_hash |
| `lib/legion/llm/types/tool_call.rb` | ToolCall Data.define struct with build, to_audit_hash |
| `lib/legion/llm/types/content_block.rb` | ContentBlock Data.define struct with text/thinking/tool_use/tool_result factories |
| `lib/legion/llm/types/chunk.rb` | Chunk Data.define struct with content_delta/done factories |
| `lib/legion/llm/config.rb` | Config entry point |
| `lib/legion/llm/config/settings.rb` | Default settings, routing/discovery/API auth defaults, auto-merge into Legion::Settings |
| `lib/legion/llm/call.rb` | Call entry point: requires all call sub-files |
| `lib/legion/llm/call/providers.rb` | Provider configuration, auto-detect, verify (was providers.rb) |
| `lib/legion/llm/call/registry.rb` | Thread-safe lex-* extension registry (was ProviderRegistry) |
| `lib/legion/llm/call/dispatch.rb` | Native provider dispatch to lex-* extensions (was NativeDispatch) |
| `lib/legion/llm/call/embeddings.rb` | generate, generate_batch, fallback chain, dimension enforcement |
| `lib/legion/llm/call/structured_output.rb` | JSON schema enforcement with native response_format and prompt fallback |
| `lib/legion/llm/call/daemon_client.rb` | HTTP routing to LegionIO daemon with 30s health cache |
| `lib/legion/llm/call/bedrock_auth.rb` | Monkey-patch for Bedrock Bearer Token auth — required lazily |
| `lib/legion/llm/call/claude_config_loader.rb` | Import Claude CLI config from ~/.claude/settings.json |
| `lib/legion/llm/call/codex_config_loader.rb` | Import OpenAI bearer token from ~/.codex/auth.json |
| `lib/legion/llm/context.rb` | Context entry point |
| `lib/legion/llm/context/compressor.rb` | Deterministic prompt compression: 3 levels, code-block-aware, stopword removal |
| `lib/legion/llm/context/curator.rb` | Async heuristic conversation curation (was ContextCurator) |
| `lib/legion/llm/discovery.rb` | Discovery entry point: run, detect_embedding_capability, can_embed? |
| `lib/legion/llm/discovery/ollama.rb` | Ollama /api/tags discovery with TTL cache |
| `lib/legion/llm/discovery/system.rb` | OS memory introspection (macOS + Linux) with TTL cache |
| `lib/legion/llm/quality.rb` | Quality entry point |
| `lib/legion/llm/quality/checker.rb` | Quality heuristics + pluggable callable (was QualityChecker) |
| `lib/legion/llm/quality/shadow_eval.rb` | Parallel shadow evaluation on cheaper models with sampling (was ShadowEval) |
| `lib/legion/llm/quality/confidence/score.rb` | Immutable ConfidenceScore Data.define struct (was ConfidenceScore) |
| `lib/legion/llm/quality/confidence/scorer.rb` | Computes ConfidenceScore from logprobs/heuristics/caller (was ConfidenceScorer) |
| `lib/legion/llm/metering.rb` | Metering module: emit, flush_spool, install_hook public API |
| `lib/legion/llm/metering/usage.rb` | Immutable Usage Data.define struct |
| `lib/legion/llm/metering/estimator.rb` | Model cost estimation with fuzzy pricing (was CostEstimator) |
| `lib/legion/llm/metering/tracker.rb` | Per-request in-memory cost accumulator (was CostTracker) |
| `lib/legion/llm/metering/tokens.rb` | Thread-safe per-session token budget accumulator (was TokenTracker) |
| `lib/legion/llm/inference.rb` | Inference entry point: requires all pipeline components |
| `lib/legion/llm/inference/request.rb` | Inference::Request Data.define struct with .build and .from_chat_args |
| `lib/legion/llm/inference/response.rb` | Inference::Response Data.define struct with .build, .from_ruby_llm, #with |
| `lib/legion/llm/inference/profile.rb` | Inference::Profile: caller-derived profiles for step skipping |
| `lib/legion/llm/inference/tracing.rb` | Inference::Tracing: trace_id, span_id, exchange_id generation |
| `lib/legion/llm/inference/timeline.rb` | Inference::Timeline: ordered event recording with participant tracking |
| `lib/legion/llm/inference/executor.rb` | Inference::Executor: 18-step skeleton with profile-aware execution and call_stream |
| `lib/legion/llm/inference/conversation.rb` | In-memory LRU (256 slots) + optional Sequel DB persistence (was ConversationStore) |
| `lib/legion/llm/inference/prompt.rb` | Prompt dispatch API: dispatch, request, summarize, extract, decide |
| `lib/legion/llm/inference/tool_adapter.rb` | Wraps Tools::Base for RubyLLM sessions (McpToolAdapter kept as alias) |
| `lib/legion/llm/inference/tool_dispatcher.rb` | Routes tool calls to MCP client / LEX runner / RubyLLM builtin |
| `lib/legion/llm/inference/audit_publisher.rb` | Publishes audit events to llm.audit exchange |
| `lib/legion/llm/inference/enrichment_injector.rb` | Converts RAG/GAIA enrichments into system prompt |
| `lib/legion/llm/inference/gaia_caller.rb` | Gaia-specific chat dispatch with phase/tick tracing |
| `lib/legion/llm/inference/mcp_tool_adapter.rb` | Backward-compat alias for ToolAdapter |
| `lib/legion/llm/inference/steps.rb` | Steps aggregator: requires all step modules |
| `lib/legion/llm/inference/steps/*.rb` | All 18+ pipeline step modules (metering, billing, rbac, classification, etc.) |
| `lib/legion/llm/router.rb` | Router: resolve, health_tracker, resolve_chain, select_candidates |
| `lib/legion/llm/router/resolution.rb` | Value object: tier, provider, model, rule, metadata, compress_level |
| `lib/legion/llm/router/rule.rb` | Rule class: from_hash, matches_intent?, within_schedule?, to_resolution |
| `lib/legion/llm/router/health_tracker.rb` | HealthTracker: circuit breaker, latency window, pluggable signal handlers |
| `lib/legion/llm/router/arbitrage.rb` | Cost-aware model selection fallback when no rules match |
| `lib/legion/llm/router/gateway_interceptor.rb` | Policy-based cloud-tier interception (model allowlist per risk tier) |
| `lib/legion/llm/router/escalation/chain.rb` | EscalationChain value object with max_attempts cap |
| `lib/legion/llm/router/escalation/history.rb` | EscalationHistory mixin: escalated?, escalation_history, final_resolution |
| `lib/legion/llm/router/escalation/tracker.rb` | Escalation event tracking |
| `lib/legion/llm/fleet.rb` | Fleet entry point: load_transport, requires dispatcher/handler/reply_dispatcher |
| `lib/legion/llm/fleet/dispatcher.rb` | Fleet RPC dispatch with routing key building, per-type timeouts |
| `lib/legion/llm/fleet/handler.rb` | Fleet request handler for GPU worker nodes |
| `lib/legion/llm/fleet/reply_dispatcher.rb` | Correlation-based reply routing, fulfill_return, fulfill_nack |
| `lib/legion/llm/audit.rb` | Audit module: emit_prompt, emit_tools, emit_skill public API |
| `lib/legion/llm/transport.rb` | Transport entry point: load_all loads exchanges + messages when Transport available |
| `lib/legion/llm/transport/message.rb` | LLM base message: context propagation, LLM headers, envelope key stripping |
| `lib/legion/llm/transport/exchanges/fleet.rb` | Transport::Exchanges::Fleet: llm.request topic exchange |
| `lib/legion/llm/transport/exchanges/metering.rb` | Transport::Exchanges::Metering: llm.metering topic exchange |
| `lib/legion/llm/transport/exchanges/audit.rb` | Transport::Exchanges::Audit: llm.audit topic exchange |
| `lib/legion/llm/transport/exchanges/escalation.rb` | Transport::Exchanges::Escalation: llm.escalation topic exchange |
| `lib/legion/llm/transport/messages/fleet_request.rb` | Transport::Messages::FleetRequest |
| `lib/legion/llm/transport/messages/fleet_response.rb` | Transport::Messages::FleetResponse |
| `lib/legion/llm/transport/messages/fleet_error.rb` | Transport::Messages::FleetError with ERROR_CODES registry |
| `lib/legion/llm/transport/messages/metering_event.rb` | Transport::Messages::MeteringEvent with tier header |
| `lib/legion/llm/transport/messages/audit_event.rb` | Transport::Messages::AuditEvent: general audit event |
| `lib/legion/llm/transport/messages/prompt_event.rb` | Transport::Messages::PromptEvent: prompt audit (always encrypted) |
| `lib/legion/llm/transport/messages/tool_event.rb` | Transport::Messages::ToolEvent: tool call audit |
| `lib/legion/llm/transport/messages/skill_event.rb` | Transport::Messages::SkillEvent: skill invocation audit |
| `lib/legion/llm/transport/messages/escalation_event.rb` | Transport::Messages::EscalationEvent: fleet-wide escalation observability |
| `lib/legion/llm/api.rb` | API entry point: registered, register_routes |
| `lib/legion/llm/api/auth.rb` | Config-driven Bearer/x-api-key auth middleware for /v1/ routes |
| `lib/legion/llm/api/native/inference.rb` | POST /api/llm/inference |
| `lib/legion/llm/api/native/chat.rb` | POST /api/llm/chat |
| `lib/legion/llm/api/native/providers.rb` | GET /api/llm/providers, GET /api/llm/providers/:name |
| `lib/legion/llm/api/native/helpers.rb` | Shared: parse_request_body, json_response, emit_sse_event, token_value |
| `lib/legion/llm/api/openai/chat_completions.rb` | POST /v1/chat/completions (streaming: data: [DONE]) |
| `lib/legion/llm/api/openai/models.rb` | GET /v1/models, GET /v1/models/:id |
| `lib/legion/llm/api/openai/embeddings.rb` | POST /v1/embeddings |
| `lib/legion/llm/api/anthropic/messages.rb` | POST /v1/messages (streaming: message_start/content_block_delta/message_stop) |
| `lib/legion/llm/api/translators/openai_request.rb` | Translates OpenAI request format to internal Inference format |
| `lib/legion/llm/api/translators/openai_response.rb` | Translates Inference::Response to OpenAI response format |
| `lib/legion/llm/api/translators/anthropic_request.rb` | Translates Anthropic request format (system param, input_schema) to internal |
| `lib/legion/llm/api/translators/anthropic_response.rb` | Translates Inference::Response to Anthropic response format |
| `lib/legion/llm/scheduling.rb` | Scheduling module: should_defer?, peak_hours?, next_off_peak, status |
| `lib/legion/llm/scheduling/batch.rb` | Non-urgent request batching with priority queue and auto-flush |
| `lib/legion/llm/scheduling/off_peak.rb` | Peak-hour deferral (delegates to Scheduling) |
| `lib/legion/llm/tools/confidence.rb` | 4-tier degrading confidence storage (was OverrideConfidence) |
| `lib/legion/llm/tools/dispatcher.rb` | Routes tool calls: MCP client / LEX runner / RubyLLM builtin |
| `lib/legion/llm/tools/interceptor.rb` | Extensible pre-dispatch intercept registry |
| `lib/legion/llm/tools/adapter.rb` | Wraps lex-* extension tool as RubyLLM::Tool (McpToolAdapter kept as alias) |
| `lib/legion/llm/tools/interceptors/python_venv.rb` | Redirects python3/pip3 tool calls to isolated venv |
| `lib/legion/llm/hooks.rb` | Hooks: before/after chat registry, run_before, run_after, install_defaults |
| `lib/legion/llm/hooks/rag_guard.rb` | Post-generation RAG faithfulness check via lex-eval |
| `lib/legion/llm/hooks/response_guard.rb` | Central post-generation safety dispatch |
| `lib/legion/llm/hooks/budget_guard.rb` | Blocks calls when session USD budget is exceeded |
| `lib/legion/llm/hooks/cost_tracking.rb` | After-chat hook: records token usage via Metering::Recorder |
| `lib/legion/llm/hooks/metering.rb` | After-chat hook: publishes metering events to AMQP |
| `lib/legion/llm/hooks/reflection.rb` | Extracts decisions/patterns/facts from conversations, publishes to Apollo |
| `lib/legion/llm/hooks/reciprocity.rb` | Records social exchange events via Social::Client |
| `lib/legion/llm/cache.rb` | Cache module: deterministic SHA256 key, guarded get/set, enabled? |
| `lib/legion/llm/cache/response.rb` | Async response delivery via memcached with spool overflow at 8MB (was ResponseCache) |
| `lib/legion/llm/skills.rb` | Skills entry point: start (load settings, disk, external discovery) |
| `lib/legion/llm/skills/base.rb` | Skills DSL base class: skill_name, trigger, steps, follows |
| `lib/legion/llm/skills/registry.rb` | Thread-safe skill registry with trigger word index and cycle detection |
| `lib/legion/llm/skills/settings.rb` | Skill-specific settings merge into Legion::Settings |
| `lib/legion/llm/skills/disk_loader.rb` | Loads skill definitions from directories |
| `lib/legion/llm/skills/external_discovery.rb` | Auto-discovers skill dirs from Claude/Codex configs |
| `lib/legion/llm/skills/errors.rb` | Skill-specific error types |
| `lib/legion/llm/skills/step_result.rb` | Immutable step execution result |
| `lib/legion/llm/skills/skill_run_result.rb` | Immutable overall skill run result |
| `lib/legion/llm/bedrock_bearer_auth.rb` | Bedrock Bearer Token auth monkey-patch (loaded lazily from call/bedrock_auth) |
| `lib/legion/llm/helper.rb` | Extension helper mixin: llm_chat, llm_embed, llm_session, llm_ask, llm_structured, etc. |
| `lib/legion/llm/helpers/llm.rb` | Backward-compat shim: includes Legion::LLM::Helper |
| `spec/legion/llm_spec.rb` | Tests: settings, lifecycle, providers, auto-config |
| `spec/legion/llm/integration_spec.rb` | Tests: routing integration with chat() |
| `spec/legion/llm/router_spec.rb` | Tests: Router.resolve, priority selection, constraints, health |
| `spec/legion/llm/router/resolution_spec.rb` | Tests: Resolution value object |
| `spec/legion/llm/router/rule_spec.rb` | Tests: Rule intent matching, from_hash, to_resolution |
| `spec/legion/llm/router/rule_schedule_spec.rb` | Tests: Rule schedule evaluation |
| `spec/legion/llm/router/health_tracker_spec.rb` | Tests: circuit breaker, latency, signal handlers |
| `spec/legion/llm/router/settings_spec.rb` | Tests: routing defaults in settings |
| `spec/legion/llm/context/compressor_spec.rb` | Tests: compression levels, code-block protection, determinism (was compressor_spec.rb) |
| `spec/legion/llm/helpers/llm_spec.rb` | Tests: helper mixin with compress integration |
| `spec/legion/llm/discovery/ollama_spec.rb` | Tests: Ollama model discovery, TTL, error handling |
| `spec/legion/llm/discovery/system_spec.rb` | Tests: System memory introspection |
| `spec/legion/llm/discovery/router_integration_spec.rb` | Tests: Router discovery filtering |
| `spec/legion/llm/discovery/startup_spec.rb` | Tests: Startup discovery warmup |
| `spec/legion/llm/discovery/settings_spec.rb` | Tests: Discovery settings defaults |
| `spec/legion/llm/quality/checker_spec.rb` | QualityChecker tests (was quality_checker_spec.rb) |
| `spec/legion/llm/router/escalation/history_spec.rb` | EscalationHistory tests (was escalation_history_spec.rb) |
| `spec/legion/llm/escalation_integration_spec.rb` | chat() escalation loop tests |
| `spec/legion/llm/router/escalation/chain_spec.rb` | EscalationChain tests (was router/escalation_chain_spec.rb) |
| `spec/legion/llm/router/resolve_chain_spec.rb` | Router.resolve_chain tests |
| `spec/legion/llm/transport/escalation_spec.rb` | Transport escalation exchange/message tests |
| `spec/legion/llm/call/embeddings_spec.rb` | Embeddings tests (was embeddings_spec.rb) |
| `spec/legion/llm/quality/shadow_eval_spec.rb` | ShadowEval tests (was shadow_eval_spec.rb) |
| `spec/legion/llm/call/structured_output_spec.rb` | StructuredOutput tests (was structured_output_spec.rb) |
| `spec/legion/llm/errors_spec.rb` | Tests: typed error hierarchy, retryable? predicate |
| `spec/legion/llm/inference/conversation_spec.rb` | Tests: LRU eviction, append, messages, DB fallback (was conversation_store_spec.rb) |
| `spec/legion/llm/inference/executor_stream_spec.rb` | Tests: call_stream chunk yielding, pre/post steps |
| `spec/legion/llm/inference/streaming_integration_spec.rb` | Tests: streaming end-to-end with Conversation |
| `spec/legion/llm/gateway_integration_spec.rb` | Tests: gateway teardown — verifies no delegation |
| `spec/legion/llm/metering/estimator_spec.rb` | Tests: cost estimation, fuzzy matching, pricing table (was cost_estimator_spec.rb) |
| `spec/legion/llm/inference/request_spec.rb` | Tests: Request struct builder, legacy adapter |
| `spec/legion/llm/inference/response_spec.rb` | Tests: Response struct builder, RubyLLM adapter, #with |
| `spec/legion/llm/inference/profile_spec.rb` | Tests: Profile derivation and step skipping |
| `spec/legion/llm/inference/tracing_spec.rb` | Tests: Tracing init, exchange_id generation |
| `spec/legion/llm/inference/timeline_spec.rb` | Tests: Timeline event recording, participants |
| `spec/legion/llm/inference/executor_spec.rb` | Tests: Executor pipeline execution, profile skipping |
| `spec/legion/llm/inference/integration_spec.rb` | Tests: Inference integration with chat() dispatch |
| `spec/legion/llm/inference/steps/metering_spec.rb` | Tests: Metering step event building |
| `spec/legion/llm/transport/message_spec.rb` | Tests: LLM base message class |
| `spec/legion/llm/fleet/exchange_spec.rb` | Tests: fleet exchange declaration |
| `spec/legion/llm/fleet/request_spec.rb` | Tests: Fleet::Request message |
| `spec/legion/llm/fleet/response_spec.rb` | Tests: Fleet::Response message |
| `spec/legion/llm/fleet/error_spec.rb` | Tests: Fleet::Error message |
| `spec/legion/llm/fleet/dispatcher_spec.rb` | Tests: Fleet dispatch, routing keys, per-type timeouts, ReplyDispatcher |
| `spec/legion/llm/fleet/handler_spec.rb` | Tests: Fleet handler, auth, response building |
| `spec/legion/llm/metering/exchange_spec.rb` | Tests: metering exchange |
| `spec/legion/llm/metering/event_spec.rb` | Tests: MeteringEvent message |
| `spec/legion/llm/metering_spec.rb` | Tests: Metering emit/spool API |
| `spec/legion/llm/audit/exchange_spec.rb` | Tests: audit exchange |
| `spec/legion/llm/audit/prompt_event_spec.rb` | Tests: PromptEvent |
| `spec/legion/llm/audit/tool_event_spec.rb` | Tests: ToolEvent |
| `spec/legion/llm/audit_spec.rb` | Tests: Audit emit API |
| `spec/legion/llm/inference/steps/rag_context_spec.rb` | Tests: RAG context strategy selection, Apollo retrieval, graceful degradation |
| `spec/legion/llm/inference/steps/rag_guard_spec.rb` | Tests: RAG faithfulness checking |
| `spec/legion/llm/inference/enrichment_injector_spec.rb` | Tests: enrichment injection into system prompt |
| `spec/legion/llm/inference/rag_gas_integration_spec.rb` | Tests: RAG/GAS full cycle integration |
| `spec/spec_helper.rb` | Real Legion::Logging and Legion::Settings for testing (no stubs) |

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

Tests run without the full LegionIO stack. `spec/spec_helper.rb` uses real `Legion::Logging` and `Legion::Settings` (no stubs — hard dependencies are always present). Each test resets settings to defaults via `before(:each)`.

```bash
bundle exec rspec    # 1661 examples, 0 failures
bundle exec rubocop  # 0 offenses
```

## Coding Constraints

These rules are enforced across all legion-llm code. Violations will be caught in review.

- **Never `::JSON`** -- Use `Legion::JSON.load` / `Legion::JSON.dump` everywhere. Bare `::JSON` bypasses the multi_json wrapper and breaks symbol-key conventions.
- **Never `defined?(Legion::Settings)` guards** -- `legion-settings` is a hard dependency. It is always present. Guarding `defined?(Legion::Settings)` is dead code that obscures intent.
- **Never swallow exceptions** -- Every `rescue` must either re-raise or call `handle_exception(e, level:, operation:)`. Silent `rescue => e; nil` hides bugs.
- **Always `handle_exception`** -- All error handling flows through `Legion::Logging::Helper#handle_exception`. This provides structured logging with operation context, level control, and future telemetry hooks.
- **Every module gets `Legion::Logging::Helper`** -- All modules and classes must `extend Legion::Logging::Helper` (modules) or `include Legion::Logging::Helper` (classes/instances). Use `log.debug`, `log.info`, `log.warn`, `log.error` -- never `puts` or `$stderr`.
- **Debug logging must be diagnostic-complete** -- Every `log.debug` call must include enough context to diagnose issues without a debugger: method name, key parameters, and result. Format: `[llm][component] action=verb key=value`.

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
