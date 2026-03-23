# Legion LLM Changelog

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
