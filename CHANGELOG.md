# Legion LLM Changelog

## [0.5.15] - 2026-03-28

### Added
- `Legion::LLM::Routes` Sinatra extension module (`lib/legion/llm/routes.rb`): contains all `/api/llm/*` route definitions (chat, inference, providers) extracted from `LegionIO/lib/legion/api/llm.rb`. Self-registers with `Legion::API.register_library_routes('llm', Legion::LLM::Routes)` at the end of `Legion::LLM.start`.

### Changed
- `Legion::LLM.start` now calls `register_routes` after setting `@started = true`, mounting routes onto the API if `Legion::API` is available.

## [0.5.14] - 2026-03-27

### Added
- `DaemonClient.inference` method for conversation-level routing — accepts a full `messages:` array and optional `tools:`, `model:`, `provider:`, and `timeout:` keyword args, posts to `POST /api/llm/inference`, and returns a structured `{ status: :ok, data: { content:, tool_calls:, stop_reason:, model:, input_tokens:, output_tokens: } }` hash on success
- `http_post` now accepts an optional `timeout:` keyword argument (default `DEFAULT_TIMEOUT = 60`) so callers like `inference` can pass a longer timeout (120s) without affecting existing `chat` calls
- `interpret_inference_response` private helper that maps the `/api/llm/inference` HTTP response — 200 returns `:ok` with structured fields, 4xx/5xx follow the same error handling as `interpret_response`

## [0.5.13] - 2026-03-27

### Changed
- Classification step (step 6) now auto-enables when `Settings.dig(:compliance, :classification_level)` is set, making it opt-out instead of opt-in when compliance profile is active

## [0.5.12] - 2026-03-26

### Added
- RagContext (step 8): `apollo_available?` now also returns true when `Legion::Apollo.started?`; `apollo_retrieve` calls `Legion::Apollo.retrieve(scope: :all)` to merge global + local results when the core library is available
- KnowledgeCapture (step 19): after global writeback, also writes response content to `Legion::Apollo::Local` when started — tags with `['llm_response', model]`
- `local_capture_enabled?` guard — only writes to local store when `Apollo::Local.started?`, no-op otherwise
- `ingest_to_local` rescues errors and appends to `@warnings` — pipeline never crashes on local ingest failure

## [0.5.11] - 2026-03-25

### Added
- `Legion::LLM.can_embed?` — cached boolean for embedding capability
- `Legion::LLM.embedding_provider` — current embedding provider symbol
- `Legion::LLM.embedding_model` — current embedding model string
- Boot-time embedding detection with configurable provider fallback chain (ollama -> bedrock -> openai)
- 1024-dimension enforcement on all embedding responses (truncate if larger, reject if smaller)
- Runtime failover: if cached embedding provider fails, walks fallback chain for next available
- `llm.embedding.*` settings block with `provider_fallback`, `provider_models`, `ollama_preferred`, `dimension`, `enforce_dimension`

### Changed
- `Embeddings.generate` now uses cached provider/model from boot detection when no explicit provider given
- `Embeddings.generate` enforces exactly 1024 dimensions by default (configurable via `enforce_dimension: false`)
- Bedrock Titan model updated to `amazon.titan-embed-text-v2:0`

## [0.5.10] - 2026-03-25

### Added
- Pipeline step 19: KnowledgeCapture — automatic writeback of LLM research synthesis to Apollo

## [0.5.9] - 2026-03-25

### Added
- Provider-aware embedding model resolution: `Embeddings.generate` and `generate_batch` accept `provider:` parameter
- `PROVIDER_EMBEDDING_MODELS` constant maps providers to their default embedding models (bedrock: `amazon.titan-embed-text-v2`, openai: `text-embedding-3-small`, gemini: `text-embedding-004`, ollama: `mxbai-embed-large`)
- Embedding fallback chain: explicit `provider:`/`model:` -> `llm.embeddings.provider`/`default_model` settings -> derive from `llm.default_provider` -> `text-embedding-3-small`
- Embedding results now include `:provider` key in response hash

## [0.5.8] - 2026-03-25

### Added
- Wire shadow evaluation sampling into `chat_single` dispatch path (closes #3)
- ToolRegistry spec coverage: 8 examples covering register, dedup, clear, thread safety (closes #4)
- Arbitrage as router fallback: `Router.resolve` consults `Arbitrage.cheapest_for` when no rules match (closes #5)
- Batch thread safety: Mutex around queue, priority-sorted flush, auto-flush via `Concurrent::TimerTask` (closes #6)
- Scheduling deferral in `chat_direct`: defers to Batch during peak hours when scheduling is enabled (closes #7)
- `publish_escalation_event` now publishes to `Legion::Events` and AMQP transport (closes #8)
- Arbitrage `quality_floor` filtering via `QualityChecker.model_score` when available (closes #9)

### Fixed
- `OffPeak.should_defer?` now checks `Scheduling.enabled?` before returning true (closes #9)
- Pre-existing ordering-dependent spec failure in `llm_spec.rb` (ToolRegistry bleed)
- Fix namespace collision: use `::Data.define` instead of `Data.define` in Pipeline Request and Response to prevent resolution to `Legion::Data`

## [0.5.6] - 2026-03-24

### Fixed
- `AuditPublisher` now uses dedicated `Transport::Messages::AuditEvent` message class instead of `Messages::Dynamic` (Dynamic ignores `exchange:`/`routing_key:` kwargs and requires a `function_id` DB lookup — audit events were never reaching RabbitMQ)
- Added `Transport::Exchanges::Audit` exchange class for the `llm.audit` topic exchange
- Added `Transport::Messages::AuditEvent` message class with `routing_key 'llm.audit.complete'`

## [0.5.5] - 2026-03-24

### Changed
- RAG context step now fires on almost all queries, not just long conversations
- RAG only skips trivial queries (greetings, pings) when strategy is auto
- All RAG thresholds configurable via `Legion::Settings[:llm][:rag]`: `full_limit`, `compact_limit`, `min_confidence`, `utilization_compact_threshold`, `utilization_skip_threshold`, `trivial_max_chars`, `trivial_patterns`
- Strategy logic inverted: low utilization gets full RAG (room for context), high utilization gets compact, very high skips

## [0.5.4] - 2026-03-24

### Added
- Declare `faraday` as explicit dependency (used in Ollama discovery and pipeline error handling)
- Declare `concurrent-ruby` as explicit dependency (used in fleet reply dispatcher)
- Declare `legion-json` as explicit dependency (used throughout for serialization)
- Declare `lex-bedrock` as explicit dependency (enterprise AWS provider out of the box)

## [0.5.3] - 2026-03-24

### Changed
- Add debug logging to 13 swallowed `rescue StandardError` blocks: `pipeline_enabled?`, ConversationStore (load_from_db, db_conversation_exists?, db_available?), BudgetGuard (budget_setting), ReplyDispatcher (parse_payload), OverrideConfidence (sync_to_l1, sync_to_l2, lookup_l1, lookup_l2), Metering (transport_metering?), Reflection (apollo_transport?), Fleet::Handler (valid_token?)

## [0.5.1] - 2026-03-24

### Fixed
- add `:caller` to `FRAMEWORK_KEYS` so caller identity is stripped before reaching `RubyLLM.chat` — fixes `unknown keyword: :caller` crash in non-pipeline paths (session creation, escalation)

## [0.5.0] - 2026-03-24

### Changed
- **Pipeline enabled by default** (`pipeline_enabled: true`) — all `Legion::LLM.chat(message:)` calls now route through the 18-step pipeline with RBAC, classification, billing, audit, and tracing
- Minor version bump: this is the culmination of Plans 1-6, Phase B governance, and consumer migration Waves 0-5 across 48 call sites in 9 repos

### Added
- Pre-rollout integration test suite (20 specs) covering caller propagation, profile skip lists, streaming, conversation round-trip, error typing, and graceful degradation

### Fixed
- OpenInference spec compatibility with pipeline-enabled default

## [0.4.7] - 2026-03-23

### Fixed
- `Legion::LLM.chat(message:) { |chunk| chunk.content }` now streams when `pipeline_enabled: false`; block is forwarded through `chat_single` to `session.ask` rather than silently ignored

### Added
- Integration specs verifying pipeline streaming yields chunks with `.content`, `caller:` flows through to `response.caller`, and non-pipeline streaming works

## [0.4.6] - 2026-03-23

### Changed
- `Pipeline::GaiaCaller.chat` and `.structured` now accept an explicit `caller:` keyword parameter and forward it to `Pipeline::Request.build`; falls back to `gaia_caller(phase)` when nil (default, no behaviour change)

## [0.4.5] - 2026-03-23

### Fixed
- `llm_chat` and `llm_session` helpers now accept and forward `caller:` to pipeline (unblocks consumer migration)

## [0.4.4] - 2026-03-23

### Added
- `Pipeline::Steps::Rbac`: real RBAC enforcement using `Legion::Rbac.authorize!`, graceful degradation when unavailable
- `Pipeline::Steps::Classification`: real PII/PHI scan (SSN, email, phone regex + PHI keyword list); upgrade-only classification levels
- `Pipeline::Steps::Billing`: real budget enforcement via `CostEstimator`; spending cap rejection

### Changed
- Extracted all three governance stubs from Executor into dedicated step modules

## [0.4.2] - 2026-03-23

### Added
- `Pipeline::Steps::RagContext` (step 8): context strategy selector (full/rag_hybrid/rag/none) based on utilization, queries Apollo via `retrieve_relevant`
- `Pipeline::Steps::RagGuard`: post-response faithfulness check against retrieved RAG context via `Hooks::RagGuard`
- `Pipeline::EnrichmentInjector`: converts RAG and GAIA enrichments into system prompt text before provider call
- `Pipeline::GaiaCaller`: privileged helper for GAIA/GAS LLM calls with system profile (skips governance steps)
- `Pipeline::AuditPublisher`: publishes audit events to `llm.audit` exchange for GAS subscriber consumption
- RAG/GAS full cycle integration test (4 examples: enrichment, injection, degradation, feedback loop prevention)
- `OverrideConfidence` module with 4-tier degrading storage (L0 memory, L1 cache, L2 SQLite, L3 Apollo)
- Catalog-driven auto-override in `ToolDispatcher`: settings override first, then Catalog + confidence gate
- Shadow mode execution: when confidence is 0.5-0.8, execute both MCP and LEX, compare results, update confidence
- `hydrate_from_l2` and `hydrate_from_apollo` for override confidence persistence across restarts

## [0.4.1] - 2026-03-23

### Added
- Typed error hierarchy (`AuthError`, `RateLimitError`, `ContextOverflow`, `ProviderError`, `ProviderDown`, `UnsupportedCapability`, `PipelineError`) with `retryable?` predicate
- `ConversationStore` with in-memory LRU hot layer (256 conversations) and optional DB persistence via Sequel
- Streaming pipeline support via `Executor#call_stream` — pre/post steps run normally, chunks yielded to caller
- Pipeline steps `context_load` (Step 3) and `context_store` (Step 15) now functional
- `Pipeline::Steps::McpDiscovery` (step 9): discovers tools from all healthy MCP servers via `Legion::MCP::Client::Pool`
- `Pipeline::ToolDispatcher`: routes tool calls to MCP client, LEX extension runner, or RubyLLM builtin
- `Pipeline::Steps::ToolCalls` (step 14): dispatches non-builtin tool calls from LLM response via `ToolDispatcher`
- `pipeline/steps.rb` aggregator for all step modules

### Changed
- Executor `step_provider_call` classifies Faraday errors into typed hierarchy
- `chat`, `embed`, and `structured` route directly without gateway delegation
- `_dispatch_embed` and `_dispatch_structured` removed; dispatch inlined

### Removed
- `lex-llm-gateway` auto-loading (`begin/rescue LoadError` block removed)
- `gateway_loaded?` and `gateway_chat` helper methods
- `_dispatch_embed` and `_dispatch_structured` indirection methods

## [0.4.0] - 2026-03-23

### Added
- `Pipeline::Request`: Data.define struct with `.build` and `.from_chat_args` for unified request representation
- `Pipeline::Response`: Data.define struct with `.build`, `.from_ruby_llm`, and `#with` for immutable responses
- `Pipeline::Profile`: Caller-derived profiles (external/gaia/system) with step skip logic
- `Pipeline::Tracing`: Distributed tracing with trace_id, span_id, and exchange_id generation
- `Pipeline::Timeline`: Ordered event recording with participant tracking
- `Pipeline::Executor`: 18-step pipeline skeleton with profile-aware step execution
- `Pipeline::Steps::Metering`: Metering event builder absorbed from lex-llm-gateway
- `CostEstimator`: Model cost estimation with fuzzy matching, absorbed from lex-llm-gateway
- `Fleet::Dispatcher`: Fleet RPC dispatch absorbed from lex-llm-gateway
- `Fleet::Handler`: Fleet request handler absorbed from lex-llm-gateway
- `Fleet::ReplyDispatcher`: Correlation-based reply routing for fleet RPC
- Feature-flagged `pipeline_enabled` setting (default: false) for incremental rollout
- Pipeline path in `_dispatch_chat` activated by `pipeline_enabled: true`

## [0.3.32] - 2026-03-23

### Added
- `Hooks::Reflection`: after_chat hook that extracts knowledge from conversations
- Detects decisions, patterns, and facts using regex markers
- Publishes extracted entries to Apollo via AMQP or direct ingest
- Cooldown-based dedup (5 min) and async extraction to avoid blocking
- `summary` method for introspection of extraction history

## [0.3.31] - 2026-03-23

### Added
- `Compressor.deduplicate_messages`: removes near-duplicate messages from conversation history using Jaccard similarity on word sets
- Configurable similarity threshold (default 0.85), keeps last occurrence, same-role-only comparison
- Skips short messages (< 20 chars) to avoid false positives

## [0.3.30] - 2026-03-23

### Added
- `Scheduling.status`: returns hash with current scheduling state (peak hours, defer intents, next off-peak)
- `Batch.status`: returns hash with queue size, priority breakdown, oldest entry, config

## [0.3.29] - 2026-03-23

### Added
- `EscalationTracker`: global escalation history with summary analytics
- Tracks model escalations (from_model, to_model, reason, tier changes)
- `summary` aggregates by reason, source model, and target model
- `escalation_rate` reports escalation frequency within configurable time windows
- Capped at 200 entries with automatic eviction

## [0.3.28] - 2026-03-23

### Added
- QualityChecker: truncation detection for responses cut off mid-sentence
- QualityChecker: refusal detection for model refusal patterns ("I can't", "as an AI")
- REFUSAL_PATTERNS constant with configurable regex patterns
- 6 new specs covering truncation and refusal detection

## [0.3.27] - 2026-03-23

### Added
- `Compressor.summarize_messages` for LLM-based conversation summarization
- Uses configurable model (default: gpt-4o-mini) for context window compression
- Falls back to aggressive stopword compression when LLM unavailable
- Short conversations returned uncompressed to avoid unnecessary API calls

## [0.3.26] - 2026-03-23

### Changed
- Enhanced ShadowEval with result history, cost comparison, and summary analytics
- `compare` now includes primary_cost, shadow_cost, and cost_savings ratio
- Added `history`, `clear_history`, and `summary` class methods
- History capped at 100 entries with automatic eviction
- Cost estimation uses CostTracker pricing when available

## [0.3.25] - 2026-03-23

### Added
- `Hooks::BudgetGuard` before_chat hook: blocks LLM calls when session cost budget is exceeded
- `BudgetGuard.status` returns enforcing state, spent, remaining, and ratio
- `BudgetGuard.remaining` returns remaining budget in USD
- Configurable via `llm.budget.session_usd` in settings (disabled when 0 or unset)
- Auto-installed during `LLM.start` only when budget is configured
- 10 specs covering blocking, passthrough, remaining, status, and enforcing checks

## [0.3.24] - 2026-03-23

### Added
- Auto cost-tracking hook: records per-request cost via `CostTracker` after every LLM call
- `Hooks::CostTracking.install` registers an `after_chat` hook during `LLM.start`
- Extracts usage tokens and model from response, feeds into in-memory `CostTracker.record`
- Opt-out via `llm.cost_tracking.auto: false` in settings
- 9 specs covering hook installation, token extraction, model fallback, and edge cases

## [0.3.23] - 2026-03-23

### Added
- Auto-metering hook: records token usage after every LLM call via gateway MeteringWriter or AMQP transport
- `Hooks::Metering.install` registers an `after_chat` hook during `LLM.start`
- Extracts input/output tokens, provider, model, status from response
- Opt-out via `llm.metering.auto: false` in settings
- 11 specs covering hook installation, data extraction, availability checks, and edge cases

## [0.3.22] - 2026-03-23

### Changed
- `Batch.submit_single` now calls `Legion::LLM.chat_direct` instead of returning a stub response
- Batch flush returns `status: :completed` on success or `status: :failed` with error on exception
- `OffPeak` module now delegates to `Scheduling` (consolidated duplicate peak-hour logic)
- `Scheduling.peak_hours?` and `Scheduling.next_off_peak` accept optional `time` parameter

## [0.3.21] - 2026-03-23

### Added
- `Legion::LLM::ToolRegistry` thread-safe tool class registry for auto-attaching tools to chat sessions
- Wire ToolRegistry into `chat_single` so globally registered tools are available in every session

### Fixed
- Fix `CostTracker.settings_pricing` reading from wrong settings key (`:'legion-llm'` instead of `:llm`)
- Fix `ShadowEval.evaluate` not passing `messages:` to shadow model (shadow got no context to respond to)

## [0.3.20] - 2026-03-22

### Changed
- Tightened gemspec dependency version constraints: `legion-logging >= 1.2.8`, `legion-settings >= 1.3.12`

## [0.3.19] - 2026-03-22

### Changed
- Added `Legion::Logging` calls to all silent rescue blocks (28 total) so no exception is swallowed without a trace
- `arbitrage.rb`, `batch.rb`, `scheduling.rb`, `router.rb`, `gateway_interceptor.rb`: `.warn` on settings unavailable
- `cache.rb`: `.warn` on llm_settings failure
- `claude_config_loader.rb`: `.debug` on JSON read failure (expected for missing files)
- `cost_tracker.rb`: `.warn` on settings_pricing failure
- `daemon_client.rb`: `.warn` on health check failure and fetch_daemon_url failure, `.debug` on JSON parse failure
- `discovery/ollama.rb`: `.debug` on base_url and discovery_settings failures
- `discovery/system.rb`: `.debug` on discovery_settings failure
- `embeddings.rb`: `.warn` on batch embedding failure
- `hooks/rag_guard.rb`: `.debug` on individual evaluator failure
- `hooks.rb`: `.warn` on before_chat and after_chat hook failures
- `providers.rb`: `.debug` on Ollama connection check failure
- `quality_checker.rb`: `.debug` on JSON validation failure
- `structured_output.rb`: `.warn` on retry failure
- `llm.rb`: `.debug` on lex-llm-gateway LoadError, `.warn` on escalation attempt failure, publish_escalation_event failure, and apply_response_guards failure

## [0.3.18] - 2026-03-22

### Added
- Logging across routing, health tracking, caching, and discovery subsystems
- `Router.resolve`: `.info` on route decision (tier/provider/model/rule), `.debug` on candidate filtering counts, `.debug` when no rules match
- `Router::HealthTracker`: `.warn` on circuit state transitions (closed->open, half_open->open, open->half_open, any->closed), `.debug` on latency penalty applied
- `Router::Rule`: `.debug` on intent mismatch, schedule constraint rejections (valid_from, valid_until, hours, days)
- `Cache`: `.debug` on cache miss and cache write, `.warn` on swallowed get/set errors
- `ResponseCache`: `.warn` on spool overflow to disk, `.debug` on async poll status, `.warn` on fail_request
- `DaemonClient`: `.warn` on mark_unhealthy, `.warn` on 403/429 responses, `.info` on health check result
- `StructuredOutput`: `.warn` on JSON parse failure with attempt count, `.debug` when using prompt-based fallback
- `Compressor`: `.debug` on compression applied (level, original length, compressed length)
- `Discovery::Ollama`: `.warn` on HTTP failure, `.debug` on model list refresh with count
- `Discovery::System`: `.warn` on system command failures (sysctl, vm_stat, /proc/meminfo)
- `ShadowEval`: `.debug` on evaluation triggered, `.warn` on failure
- `Scheduling`: `.debug` on defer decision
- `OffPeak`: `.debug` on peak hour check result
- `Arbitrage`: `.debug` on model selection result

### Changed
- `Router::Rule#within_schedule?` refactored to extract `schedule_rejection` helper (reduces cyclomatic complexity)

## [0.3.17] - 2026-03-22

### Added
- `Legion::LLM::OffPeak` module for off-peak scheduling: `peak_hour?`, `should_defer?(priority:)`, `next_off_peak` — defers non-urgent LLM requests during configurable peak hours (default 14:00-22:00 UTC)
- `Legion::LLM::CostTracker` module for per-request cost tracking: `record(model:, input_tokens:, output_tokens:)`, `summary(since:)` with by-model breakdown, configurable pricing table via settings, thread-safe accumulator

## [0.3.16] - 2026-03-22

### Fixed
- `chat_single` now accepts and forwards `message:` kwarg, calling `session.ask(message)` when present instead of returning a bare session object
- `chat_direct` passes `message:` through to `chat_single` in the non-escalation branch
- Add `FRAMEWORK_KEYS` constant to strip Runner.run metadata kwargs (`task_id`, `source`, `timestamp`, etc.) before passing to RubyLLM
- Move `FRAMEWORK_KEYS` out of `private` scope (constants are not affected by `private` in Ruby)

## [0.3.15] - 2026-03-21

### Changed
- Pin ruby_llm dependency from `>= 1.0` to `~> 1.13` to prevent breaking changes from a future 2.0 release

## [0.3.14] - 2026-03-21

### Added
- `Legion::LLM::Arbitrage` module for cost-aware model selection: configurable cost table (per-1M-token input/output prices), `cheapest_for(capability:, max_cost:)` filters eligible models and returns the cheapest, `estimated_cost` for per-request USD estimates, settings-defined cost_table overrides, quality_floor and capability-tier filtering
- `Legion::LLM::Batch` module for non-urgent request batching: `enqueue` stores requests in an in-process queue with UUID tracking, `flush` groups by provider/model and invokes callbacks, configurable window_seconds and max_batch_size, `reset!` for test isolation
- `Legion::LLM::Scheduling` module for off-peak deferral: `should_defer?(intent:, urgency:)` checks configurable peak hours and intent eligibility, `peak_hours?` evaluates UTC hour against configurable range, `next_off_peak` returns next off-peak window capped at max_defer_hours
- Default settings for all three features under `llm.arbitrage`, `llm.batch`, `llm.scheduling` — all disabled by default (opt-in)
- 3 new spec files: `arbitrage_spec.rb` (18 examples), `batch_spec.rb` (16 examples), `scheduling_spec.rb` (24 examples)

## [0.3.13] - 2026-03-21

### Added
- `Legion::LLM::Hooks::RagGuard` module with `check_rag_faithfulness` for post-generation RAG faithfulness evaluation via lex-eval
- `Legion::LLM::Hooks::ResponseGuard` module with `guard_response` as the central dispatch point for post-generation safety checks
- Response guard wired into `_dispatch_chat`: fires when `Legion::Settings[:llm][:response_guards][:enabled]` is true, attaches `_guard_result` metadata to the response hash without blocking
- RAG guard skips gracefully when lex-eval is unavailable (returns `reason: :eval_unavailable`) or context is not provided (returns `reason: :no_context`)
- Settings keys: `llm.rag_guard.enabled`, `llm.rag_guard.threshold` (default 0.7), `llm.rag_guard.evaluators` (default `[:faithfulness, :rag_relevancy]`)
- 19 new specs in `spec/legion/llm/hooks/rag_guard_spec.rb` and `spec/legion/llm/hooks/response_guard_spec.rb`

## [0.3.12] - 2026-03-19

### Added
- `Legion::LLM::Cache` module with deterministic SHA256 key generation, guarded `get`/`set`, and `enabled?` check
- Application-level response caching in `chat_direct` via `legion-cache` (Legion::Cache guard required)
- Cache skip conditions: `cache: false` option, `temperature > 0`, nil message, or cache disabled
- Cache hits return `{ cached: true }` merged into response metadata
- Anthropic prompt caching support: injects `cache_control: { type: "ephemeral" }` into system messages longer than `min_tokens` when provider is anthropic
- `prompt_caching` settings section with `enabled`, `min_tokens`, `response_cache.enabled`, `response_cache.ttl_seconds` defaults
- 25 new specs in `spec/legion/llm/cache_spec.rb` covering key determinism, hit/miss flows, skip conditions, and Legion::Cache unavailability guard

## [0.3.11] - 2026-03-20

### Added
- `Legion::LLM::Hooks` module with before/after chat hook registry
- `Hooks.before_chat` and `Hooks.after_chat` for registering interceptor blocks
- `Hooks.run_before` and `Hooks.run_after` with `:block` action support for guardrail enforcement
- `Hooks.reset!` for test isolation
- Before/after hook invocation wired into `_dispatch_chat` for transparent request interception

## [0.3.10] - 2026-03-20

### Added
- `PrivacyModeError` raised when cloud LLM tier is used with `enterprise_data_privacy` enabled
- `assert_cloud_allowed!` guard in `chat_single` and `ask_direct` blocks cloud-tier dispatch
- `Router.tier_available?(:cloud)` returns false when enterprise privacy mode is active
- Cloud provider detection covers bedrock, anthropic, openai, gemini, and azure

## [0.3.9] - 2026-03-20

### Added
- OpenInference OTel span wrapping for chat, embed, and structured methods

## [0.3.8] - 2026-03-20

### Added
- Azure AI Foundry provider: `api_base`, `api_key`, `auth_token` settings
- `configure_azure` wires RubyLLM for Azure OpenAI endpoints (api-key or bearer token auth)
- Azure added to auto-detection priority chain (position 5, between Gemini and Ollama)
- Credentials support `vault://` and `env://` resolver URIs via settings secret resolver

## [0.3.7] - 2026-03-19

### Added
- `ResponseCache` module for async response delivery via memcached with spool overflow at 8MB
- `DaemonClient` module for HTTP routing to LegionIO daemon with health caching (30s TTL)
- `Legion::LLM.ask` one-shot method: daemon-first routing with direct RubyLLM fallback
- `DaemonDeniedError` and `DaemonRateLimitedError` error classes
- Daemon settings: `daemon.url` and `daemon.enabled` in defaults
- HTTP status code contract: 200 (cached), 201 (sync), 202 (async poll), 403, 429, 503

## [0.3.6] - 2026-03-18

### Added
- Add `lex-claude`, `lex-gemini`, `lex-openai` as runtime dependencies (AI provider extensions)

## [0.3.5] - 2026-03-18

### Added
- Gateway integration: `chat`, `embed`, `structured` delegate to `lex-llm-gateway` when loaded for automatic metering and fleet dispatch
- `chat_direct`, `embed_direct`, `structured_direct` methods bypass gateway (used by gateway runners to avoid recursion)
- Gateway integration spec (8 examples)

## [0.3.4] - 2026-03-18

### Added
- Auto-configure LLM providers from environment variables (`AWS_BEARER_TOKEN_BEDROCK`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CODEX_API_KEY`, `GEMINI_API_KEY`)
- `ANTHROPIC_MODEL` env var sets default model for Anthropic and Bedrock providers
- Import Claude CLI config from `~/.claude/settings.json` and `~/.claude.json`
- Auto-detect Ollama via local port probe (no env var needed)
- Auto-enable providers when credentials are found in environment

## [0.3.3] - 2026-03-17

### Added
- `Router::GatewayInterceptor`: optional gateway routing mode for cloud-tier LLM calls
- Gateway settings: endpoint, API key, model policy per risk tier, fallback_to_direct
- Identity header builder: X-Agent-Id, X-Tenant-Id, X-AIRB-Project-Id, X-Risk-Tier
- Model selection policy: fnmatch-based allowlist per risk tier
- Wired gateway interceptor into `chat_single` for automatic cloud-tier interception

## [0.3.2] - 2026-03-16

### Added
- `Legion::LLM::Embeddings` module — structured wrapper around RubyLLM.embed with `generate`, `generate_batch`, `default_model`
- `Legion::LLM::ShadowEval` module — parallel evaluation on cheaper model with configurable sample rate for quality comparison
- `Legion::LLM::StructuredOutput` module — JSON schema enforcement with native `response_format` for capable models and prompt-based fallback with retry logic
- `embed_batch` and `structured` convenience methods on `Legion::LLM`
- `Settings.dig` support in spec_helper for nested settings access in tests

## [0.3.1] - 2026-03-16

### Removed
- `vault_path` provider setting (superseded by universal `vault://` resolver in legion-settings 1.3.0)
- `resolve_credentials` and related methods from Providers module

## [0.3.0] - 2026-03-16

### Added
- Model escalation on retry: automatic fallback to more capable models on hard or quality failures
- `Router.resolve_chain` returns ordered `EscalationChain` of fallback resolutions
- `QualityChecker` module with built-in heuristics (empty, too_short, repetition, json_parse) and pluggable checks
- `EscalationHistory` mixin tracks attempts on response objects (`escalated?`, `escalation_history`, `final_resolution`)
- `chat(escalate: true, message:)` retry loop with configurable `max_escalations:` and `quality_check:`
- HealthTracker `:quality_failure` signal with half-weight failure counting (6 quality failures to trip circuit)
- AMQP transport: `llm.escalation` exchange + `EscalationEvent` message for fleet-wide observability
- Settings: `routing.escalation.enabled`, `max_attempts`, `quality_threshold`
- Helper passthrough: `llm_chat` accepts `escalate:`, `max_escalations:`, `quality_check:`

## [0.2.3]

### Added
- Timezone support for routing schedule windows via TZInfo
- `within_schedule?` converts `now` to the schedule's IANA timezone before evaluating hours and days
- `tzinfo` (>= 2.0) runtime dependency

## [0.2.2]

### Added
- `Legion::LLM::Discovery::Ollama` module — queries Ollama `/api/tags` for pulled models with TTL cache
- `Legion::LLM::Discovery::System` module — queries OS memory (macOS `vm_stat`/`sysctl`, Linux `/proc/meminfo`) with TTL cache
- Router step 4.5: rejects Ollama rules where model is not pulled or exceeds available memory
- Discovery settings: `enabled`, `refresh_seconds`, `memory_floor_mb` under `Legion::Settings[:llm][:discovery]`
- Startup discovery: logs available Ollama models and system memory when Ollama provider is enabled

### Changed
- Added SimpleCov for test coverage reporting

## [0.2.1]

### Added
- `Legion::LLM::Compressor` module for deterministic prompt compression
- Three compression levels: light (articles/filler), moderate (+connectives), aggressive (+low-signal words, whitespace collapse)
- Code block protection (fenced and inline code preserved)
- `compress_level` field on `Router::Resolution` for routing-driven compression
- `compress:` parameter on `llm_chat` helper for opt-in compression
- Routing rules can specify `compress_level` in target to auto-compress for cost-sensitive tiers

## [0.2.0]

### Added
- Dynamic weighted routing engine (`Legion::LLM::Router`)
- Intent-based dispatch with privacy, capability, and cost dimensions
- Priority-based rule matching with time-based schedule windows
- Cost multipliers for economic routing (e.g., provider promotions)
- HealthTracker with circuit breaker pattern and latency rolling window
- Pluggable signal handlers for extensible health monitoring
- `intent:` and `tier:` parameters on `chat`, `llm_chat`, and `llm_session`
- Routing rules configurable via `Legion::Settings[:llm][:routing]`
- Three-tier routing: local (Ollama), fleet (Transport/AMQP), cloud (API providers)

## v0.1.0
* Initial release
* Core module with start/shutdown lifecycle
* Provider configuration (Bedrock, Anthropic, OpenAI, Gemini, Ollama)
* Vault credential resolution for all providers
* Chat, embed, and agent convenience methods
* Extension helper mixin for LEX extensions
* Auto-detection of default model from enabled providers
