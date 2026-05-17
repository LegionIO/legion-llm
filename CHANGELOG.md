# Legion LLM Changelog

## [0.9.30] - 2026-05-16

### Fixed
- Tools: API-submitted client tools are no longer advertised to providers unless callers explicitly opt into client-tool passthrough, preventing incomplete tool calls from ending streaming responses.

## [0.9.29] - 2026-05-16

### Added
- Routing: generated discovery rules now expose `:tools` capability rules for tool-capable models and normalize provider aliases such as `function_calling`/`functions`.

### Changed
- Routing: automatic routing honors top-level `llm.tier_order` before routing-specific tier priority settings.
- Routing: stream requests with injected native tools now require both `streaming` and `tools` model capabilities before selecting a target.

### Fixed
- Router: required model capabilities filter out non-tool-capable candidates instead of selecting a local model that later rejects tool payloads.
- Executor: streaming provider calls now use the escalation chain, so provider errors like "does not support tools" can move to the next routed model.
- Executor: synthetic routing requirements no longer make model-only or explicit-provider requests bypass provider inference or registry defaults.

## [0.9.28] - 2026-05-15

### Added
- API: `/api/llm/models` now surfaces a static `LegionIO` model (`id: legionio`) as the default auto-routing placeholder.

### Changed
- Routing: `model: "legionio"` clears explicit provider/model/instance/tier routing and sends the request through the router chain using the configured default intent.
- Routing: default tier priority now includes `direct` between `local` and `fleet`, and discovery-generated rule scores honor `routing.tier_priority`.

### Fixed
- Prompt dispatch: provider-inferable model-only calls such as `gpt-5.4` infer the provider instead of pairing the model with `llm.default_provider`.
- Executor: provider-tier lookup failures are logged and return nil instead of silently defaulting to `:cloud`.
- LexLLMAdapter: optional content-block accessor fallbacks now capture and debug-log probe errors instead of bare-rescuing them.
- Auto routing: unresolved `legionio` requests now raise a clear provider error instead of falling back to configured defaults.
- Routing: model-only requests stay on provider inference while explicit provider/instance/tier requests still get registry defaults without requiring rule routing.

## [0.9.27] - 2026-05-15

### Fixed
- Router/Executor: provider-scoped instance resolution no longer applies a global `llm.default_instance` to models inferred for another provider; invalid explicit instances now fall back to that provider's registered default instance instead of dispatching to an unregistered `provider/instance` pair.

## [0.9.26] - 2026-05-15

### Fixed
- Discovery: `detect_embedding_from_registry` no longer sets `@can_embed = true` when no model is resolvable — adds `first_embedding_model_for(provider, instance)` as a third fallback scanning the discovered model catalog; returns `false` (allowing legacy probe to run) when all three sources yield nothing (#121)
- RagContext: `positive_integer` no longer raises `TypeError` when `value` is nil or an empty string — adds empty-string guard before `Kernel#Integer()` call so GAIA advisory `context_window: nil` does not abort the inference pipeline (#122)
- LexLLMAdapter: `text_part_content` now handles Anthropic-style `[{type:"text", text:"…"}]` content block arrays — flattens them to plain text instead of calling `.to_s` on the array, preventing Ruby array literals from leaking into provider prompts (#123)
- Embeddings/Discovery: `embedding_config_value` and `embedding_settings` now accept the deprecated plural `"embeddings"` key alongside the canonical singular `"embedding"` key, emitting a deprecation warning; fixes silent misconfiguration when users follow doc examples that used the plural spelling (#124)

## [0.9.25] - 2026-05-14

### Added
- Router: `TIER_RANK` constant — ordered quality ranking of tiers (local → direct → fleet → openai_compat → cloud → frontier)
- Router: `explicit_resolution` promoted to public — callable directly from executor without `send`
- Router: `chain_from_defaults` appends all registered fallback providers after the primary so the chain has real alternatives to escalate to (previously single-entry when a default provider was configured)
- Executor: `run_escalation_resolution` extracted from escalation loop — encapsulates per-attempt dispatch, error rescue, and `tried[]` tracking
- Executor: `skip_same_tier!` — on `ContextOverflow`, immediately skips all remaining same-tier candidates and routes to a higher-tier provider with a larger context window
- Executor: lateral vs. escalation move classification in per-attempt log line (`move=lateral` for same-tier, `move=escalation` for higher-tier)

### Fixed
- Router: `explicit_resolution` handles nil `provider` and nil `tier` without raising `NoMethodError`
- Executor: `build_fallback_resolutions` sorts lateral alternatives (same-tier) before escalation candidates (higher-tier) — tries other instances at the same tier before promoting to a more expensive one
- Executor: deduplication in escalation loop is fully safe — `tried` entry is recorded on all rescue paths and on quality failure
- EscalationChain: `padded_resolutions` no longer pads the list by repeating the last resolution — only real distinct options are tried

## [0.9.24] - 2026-05-14

### Fixed
- API: `instance` from POST body was silently dropped — never forwarded into routing hash
- Executor: Gaia advisory tier assignment no longer overrides explicit `provider`+`instance` from caller
- Executor: `instance` now passed through `routing_resolution_for` to `Router.resolve`/`resolve_chain`
- Executor: `build_default_escalation_chain` now passes resolved provider/instance/model — previously ignored them and built a full auto chain, routing to vllm/fleet instead of the requested provider
- Router: `resolve`/`resolve_chain` accept `instance:` param; short-circuit to `explicit_resolution` when `provider` or `instance` is set (not just `tier`)
- Router: `explicit_resolution` honors caller-supplied instance instead of always pulling from registry; infers tier from `PROVIDER_TIER` when not explicitly given

## [0.9.23] - 2026-05-13

### Added
- Router: `registry_entry_for_provider` for explicit provider model resolution
- Router: model denylist (`deny_model`, `model_denied?`, `excluded_by_denial?`) — config errors auto-deny models
- Executor: config error detection (`CONFIG_ERROR_PATTERNS`) — prevents circuit breaker trips on auth/validation errors
- Executor: step timing hash on response (`metrics.timing`, `metrics.latency_legionio_ms`)
- API: `/api/llm/inference` response includes `provider`, `instance`, `tier`, `metrics`
- API: `/api/llm/providers` surfaces `source` and `credential_fingerprint`
- Inventory: provider-scoped queries skip unrelated providers
- Metering: disk-based JSONL spool when transport unavailable (was dropping events)
- Discovery: `report_discovery_failure` reports connection failures to health tracker
- Providers: `enabled: false` instances not registered; `default_model` in metadata

### Changed
- Router: tier-aware model fallback — global default no longer bleeds across providers
- Inventory: single-source offerings (native_provider preferred over discovery to eliminate duplicates)
- Inventory: dedup normalizes `"default"` instance name
- Discovery: concise connection error log (no stacktrace for unreachable providers)
- Settings: removed `claude` from `native_providers` list

### Fixed
- Cache spec rewritten to use real `Legion::Cache` instead of fragile stubs

## [0.9.22] - 2026-05-12

### Added
- Pin `legion_list_special_tools` before client and registry tools so models can inspect Legion special tools and the current `Legion::Settings::Extensions` inventory.
- Surface special Ruby runtime execution with current process/PATH environment metadata, and add Legion-managed Python and pip tools when `legionio setup python` is available.

### Changed
- Route Python command interception through the same Legion Python runtime detection used by special tool injection.
- Replace ad hoc `/api/llm/inference` tool-payload debug prints with structured debug logging.

### Fixed
- Chunk Ollama embedding requests according to configured model context limits and aggregate chunk vectors so large Apollo knowledge-capture documents do not exceed provider context windows.

## [0.9.21] - 2026-05-12

### Fixed
- Route metering strictly through `legion-transport`, dropping events when transport is unavailable instead of writing metric events to `Legion::Data::Spool`.
- Keep override confidence database access read-only by removing `Legion::Data::Local` upserts from `legion-llm`.
- Stop conversation history and sticky state from writing directly to `Legion::Data` tables.

## [0.9.20] - 2026-05-12

### Added
- Added `llm.gaia.advisory_enabled`, defaulting to `true`, so GAIA pre-request advisory shaping can be disabled without code changes.

### Fixed
- Preserve accumulated streamed native tool-call arguments from lex-llm provider responses instead of rebuilding final responses from partial stream chunks.
- Symbolize extension tool arguments before invoking runner keyword methods so JSON string keys such as `chat_id` satisfy Ruby keyword parameters.
- Match tool triggers from `Legion::Settings::Extensions` registry entries and keep registry tools injectable alongside client tools with better diagnostics.
- Skip trigger matching cleanly when `Legion::Settings::Extensions` is not loaded instead of warning through a rescued `NameError`.
- Accumulate only stream fallback state in the lex-llm adapter instead of retaining every streamed chunk when providers return final messages.
- Apply explicit vLLM tool-name forcing only on the first native tool-loop round, allowing follow-up automatic tool calls after the requested tool returns.
- Ignore absent GAIA advisory context-window limits when sizing RAG retrieval instead of routing nil through debug exception handling.

## [0.9.19] - 2026-05-11

### Added
- `GET /api/llm/tiers` — full RESTful tier hierarchy endpoint with sub-routes: `/:tier`, `/:tier/providers`, `/:tier/providers/:provider`, `/:tier/providers/:provider/instances`, `/:tier/providers/:provider/instances/:instance`, `/:tier/providers/:provider/instances/:instance/models`, `/:tier/providers/:provider/models`. Returns tier availability, provider health, instance details, and model listings in a structured tree.
- `POST /api/llm/inference` now accepts `tier` parameter in request body, passed through to the routing pipeline via `Request.extra[:tier]`. Supports values: `local`, `fleet`, `openai_compat`, `cloud`, `frontier`.
- Request log for `/api/llm/inference` now includes `requested_tier` field.

### Changed
- `GET /api/llm/offerings` response restructured from flat array to grouped hash: `tier → provider → instance → [offerings]`. Individual offering lookup (`GET /api/llm/offerings/:id`) unchanged.

## [0.9.18] - 2026-05-11

### Fixed
- `NativeResponseAdapter` now coerces tool_calls from the Hash-keyed-by-name format (returned by OpenAI-compatible providers via lex-llm) into a flat Array of Hashes, preventing TypeError crashes in `step_tool_calls`, `response_tool_calls`, and the native tool loop when streaming tool-use responses from vllm/ollama.
- `LexLLMAdapter#normalize_messages` merges enriched system content with an existing system message at index 0 instead of prepending a duplicate, preventing vllm "System message must be at the beginning" rejections during gaia narrator ticks.

## [0.9.17] - 2026-05-11

### Fixed
- `total_memory_mb` now fetched exactly once on first access and never re-fetched; hardware memory is static so repeated `sysctl` calls every 60s were wasteful. `refresh!` only clears the available memory cache; `reset!` still clears everything (for tests).
- `trivial_query?` now correctly identifies short/trivial messages: a query is trivial if it matches a known trivial pattern (exact normalized match), or if no custom patterns are configured and the query is short (under `trivial_max_chars`) and a single word. Previously, an empty patterns list caused `.any?` to always return false, so nothing was ever trivial.
- Added `trivial_patterns` helper with configurable defaults (`ping`, `pong`, `ding`, `test`, `foobar`) readable via `rag.trivial_patterns` setting; when custom patterns are explicitly configured, the short-query heuristic is disabled so only listed patterns are treated as trivial.

## [0.9.16] - 2026-05-11

### Fixed
- Renamed `Metering#settings_value` to `extract_hash_value` to fix method shadowing with `Legion::Logging::Helper#settings_value`, which resolves a `wrong number of arguments (given 3, expected 2)` error raised from `instance_log_level` when metering is active.

## [0.9.15] - 2026-05-08

### Fixed
- Normalize structured user message content before RAG query handling, preventing multipart API messages from crashing trivial-query detection or reaching Apollo as arrays.
- Normalize empty string tool-call arguments to `{}` and make sticky tool history tolerate non-hash argument payloads without dropping state writes.
- Pass non-executable API client tool calls through to callers as streaming `tool-call` events instead of dispatching them server-side as failed tool executions.
- Add runtime logging for client tool receipt, native tool injection summaries, registry-injection skips, and returned tool-call SSE emission.

## [0.9.14] - 2026-05-08

### Fixed
- Guard discovery-first provider inference when the lightweight discovery namespace is loaded before the full discovery cache API.
- Clean up publisher-identity review follow-up by making request identity fallback explicit and removing unused caller identity requires.

## [0.9.13] - 2026-05-08

### Fixed
- Allow trigger-matched registry tools to reach native provider dispatch even when `Settings::Extensions` has no always-loaded tools registered.
- Pass native dispatch options as top-level fleet request parameters so fleet providers receive `system`, `tools`, and offering metadata consistently with direct dispatch.

## [0.9.12] - 2026-05-07

### Fixed
- Route LLM AMQP publisher identity, API fallback caller identity, prompt audit attribution, and metering attribution through the local `Legion::Identity::Process` identity instead of trusting request-supplied caller hashes.
- Preserve request caller context separately from publisher identity headers, including prompt audit request caller type, skill events, escalation events, fleet envelopes, reflection ingest metadata, and privacy-blocked audit events.

## [0.9.11] - 2026-05-07

### Fixed
- `infer_provider_for_model` now consults `Discovery.cached_discovered_models` before falling back to static regex patterns, so models reported by registered lex-llm-* providers route correctly regardless of naming convention.
- Add Bedrock vendor prefix detection (`anthropic.`, `meta.`, `mistral.`, etc.) before the Ollama catch-all pattern to prevent Bedrock model IDs like `anthropic.claude-opus-4-5-20251101-v1:0` from being misrouted to Ollama due to the `:` in the version suffix.
- `inferred_provider_tier` now checks `Call::Registry` metadata for the provider's tier before falling back to the static `PROVIDER_TIER` hash.
- Restore `thinking` option in `native_dispatch_chat_options` where provider dispatch expects it.

## [0.9.10] - 2026-05-07

### Fixed
- `normalize_model_for_rules` now passes the `tier` field from each discovered model entry through to `RuleGenerator`, so per-instance tier configuration is no longer silently dropped.
- `RuleGenerator#generate` now prefers a per-model `tier` value from discovery data over the hardcoded `TIER_MAP` provider default, allowing directly-reachable vLLM (and other HTTP-based) instances to route via `:direct` instead of always being assigned `:fleet`.

## [0.9.9] - 2026-05-07

### Fixed
- Initialized sticky-state persistence reads explicitly on cache misses to satisfy static analysis without changing runtime behavior.
- Consume GAIA advisory `tool_hint`, `suppress`, and `context_window` data when building native tool definitions and sizing RAG retrieval, so GAIA advisory outputs affect provider calls instead of only appearing in enrichment summaries.

## [0.9.8] - 2026-05-06

### Fixed
- Fixed Anthropic Messages request normalization for multi-block content.
- Marked API-submitted client tools as non-executable server-side while preserving trusted registry/deferred tool injection.
- Preferred explicit settings overrides over registry MCP overrides.
- Added structured-output parse retries through alternate routes when an escalation route is available.
- Added bounded metering spool writes, disabled-vs-dropped audit results, and warning logs for invalid settings paths and invalid inventory offerings.
- Preserved non-text message content for audit/persistence and extracted string-keyed text blocks correctly.
- Added trackable unknown caller identity defaults for audit/transport envelopes.
- Used provider embedding usage tokens when formatting OpenAI-compatible embedding responses.
- Serialized daemon-client cached state behind a shared mutex.
- Added escalation transport exchange binding for escalation events.

## [0.9.7] - 2026-05-06

### Fixed
- Enabled arbitrage by default, added zero-cost local/fleet offering coverage, and removed the dead `Quality::Checker.model_score` dependency from arbitrage eligibility.
- Skipped debate when fewer than two distinct models are available and captured judge evaluation/confidence separately from the final answer.
- Reused the shared context token estimator for billing preflight cost checks.
- Logged dropped metering emissions at the inference metering call site.
- Added resolved model metadata to routing span attributes.
- Stopped treating standalone email addresses as PII by default while preserving contextual and opt-in email detection.
- Allowed context curation to choose vLLM/MLX local or fleet models for LLM-assisted summarization.
- Routed compressor summarization through standard low-cost/basic intent when no explicit compressor model is configured.

## [0.9.6] - 2026-05-06

### Fixed
- Enforced privacy classification as a forced local routing constraint, even when callers request a cloud tier.
- Made RAG faithfulness failures block caller-visible responses by default and record structured audit data.
- Archived dropped conversation turns into Apollo with conversation-scoped tags and retrieved archived history during RAG context loading.
- Reported escalation quality failures and low-confidence responses to `Router::HealthTracker` as quality signals.
- Persisted conversation sticky state through the database path and restored it after in-memory LRU eviction.
- Counted pending conversation-history and RAG enrichments in token-budget checks before provider dispatch.
- Averaged provider health priority adjustments across instances while preserving worst-state circuit reporting.

## [0.9.5] - 2026-05-06

### Fixed
- Fixed context curator cache invalidation and stored curated-summary replay so compacted messages are used on later turns.
- Persisted curation marker records even when a pass does not rewrite individual messages, allowing structural curation to run for short-message turns.
- Fixed compressor LLM summarization to call `Legion::LLM.chat_direct` with a prompt message instead of the obsolete session-style API.
- Warn and omit misleading zero-dollar cost estimates when provider usage metadata collapses to zero tokens for a known model.

## [0.9.4] - 2026-05-06

### Changed
- Added shared inference step logging helpers and debug-level step enter/complete/failure logs.
- Added safe debug/info instrumentation across inference steps for routing actions, enrichment decisions, tool handling, RAG, skill injection, sticky runner state, billing, classification, debate, post-response audit, and metering emission.

## [0.9.3] - 2026-05-06

### Changed
- Delegated responder-side fleet provider execution, token validation, and provider response publishing to the shared `lex-llm` fleet helpers.
- Kept `legion-llm` as the request-side fleet dispatcher and token issuer while retaining compatibility aliases for old responder constants.
- Bumped the `lex-llm` dependency floor to `>= 0.4.3` for shared responder execution helpers.

## [0.9.2] - 2026-05-06

### Fixed
- Prefer namespaced caller ids over ambiguous display identities when publishing audit, metering, and transport identity metadata.

## [0.9.1] - 2026-05-06

### Changed
- `legion-llm` now owns lex-llm provider registration by scanning loaded provider modules, constructing `LexLLMAdapter` instances, and writing `Call::Registry`.
- Provider rediscovery now rebuilds registry entries after `Call::Registry.reset!`, supporting LegionIO reload/hot-update flows without relying on provider require-time side effects.
- Bumped the `lex-llm` dependency floor to `>= 0.4.1` for pure provider discovery and alias metadata.

### Fixed
- Preserve streaming thinking chunks that providers emit as plain strings.
- Normalize discovered provider instance ids from provider offerings before memory-gate and availability checks.
- Use canonical offering aliases for metering cost estimates and fall back to caller agent metadata for fleet context.
- Preserve extension, string, and top-level caller identity metadata in audit events and transport headers.

## [0.9.0] - 2026-05-06

### Changed
- Added shared provider-owned fleet responder execution support for lex-llm provider gems.
- Moved fleet dispatch defaults to top-level `fleet.dispatch`, removed legacy gateway defaults, and rejected `routing.use_fleet` / `openai_compat.gateways` settings during validation.
- OpenAI-compatible routing now resolves through registered `lex-llm-openai` provider instances instead of gateway interceptor configuration.
- Native dispatch now routes chat, stream, embed, image, and health calls through the canonical lex-llm provider-instance adapter contract.
- Native inference now records direct/fleet route attempts with dispatch path, idempotency key, selected lane, failure reason, and escalation context.
- Native inference and `/api/llm/inference` now strip provider thinking from caller-visible content and expose thinking only through explicit diagnostic fields/events.
- Inventory and provider/model API reads now use cached discovery and non-live provider offerings, so explicit discovery refresh remains the only path that probes provider endpoints.
- Fleet dispatch now publishes shared lex-llm protocol-v2 envelopes with canonical `operation`, `request_id`, `correlation_id`, `idempotency_key`, signed tokens, and strict reply matching.
- Fleet worker handling now validates protocol-v2 envelopes, enforces token/idempotency policy, dispatches local providers through canonical lex-llm methods, and publishes shared lex-llm response/error envelopes.
- Bumped dependency floors to `lex-llm >= 0.4.0` and `legion-transport >= 1.4.14` for shared provider contracts and fleet envelopes.

### Removed
- Removed the gateway interceptor runtime path and gateway metering fallback.
- Retired `Legion::LLM::Transport::Messages::FleetRequest`, `FleetResponse`, and `FleetError` as fleet message authorities in favor of `Legion::Extensions::Llm::Transport::Messages::*`.

## [0.8.51] - 2026-05-03

### Changed
- Native `/api/llm/inference` streaming hides provider thinking deltas by default, with `include_thinking: true` as the explicit diagnostic opt-in.
- Pipeline metering events now carry wall-clock latency, estimated cost, conversation/correlation ids, billing, task, agent, identity, and routing context.
- LLM transport messages now preserve caller identity, credential, and caller type headers from nested caller metadata, top-level identity metadata, and extension callers.

### Fixed
- Prompt audit events now include provider response thinking separately from assistant response content.
- Native lex-llm dispatch now carries provider thinking separately from response content before API responses are emitted.
- Native discovery now normalizes provider offering objects before generating routing candidates, preserving provider instance, tier, capabilities, context length, and parameter metadata.

## [0.8.50] - 2026-05-03

### Fixed
- Native discovery now normalizes lex-llm `ModelOffering` objects before generating routing candidates, allowing auto-rules to populate from provider adapters again.

## [0.8.49] - 2026-04-29

### Changed
- `Settings.register_defaults!` now calls `Legion::Settings.register_library` instead of `merge_settings`, using the idempotent legion-settings 1.4.0 API that prevents double-registration.
- Bumped `legion-settings` dependency floor to `>= 1.4.0`.
- Test stub `Legion::Settings` now exposes `register_library` matching the real 1.4.0 API.

## [0.8.48] - 2026-04-29

### Added
- `ToolDefinition.from_registry_entry` builds tool definitions from `Legion::Settings::Extensions` registry entries.
- `Dispatcher` checks `Settings::Extensions` for tool override resolution; when no matching entry is found it falls back to settings-based MCP overrides (no `Tools::Registry` or `Catalog::Registry` fallback).
- `Executor#add_registry_tool_definitions` reads from `Settings::Extensions` when available, falling back to `Legion::Tools::Registry` for backward compatibility.
- `Steps::ToolDiscovery` discovers tools from `Settings::Extensions` when available, falling back to `Legion::Tools::Registry`.

### Changed
- Bumped `legion-settings` dependency floor to `>= 1.4.0` (requires `Settings::Extensions` module).

## [0.8.47] - 2026-04-29

### Fixed
- Tool-bearing native inference now forwards native tool definitions and runs a bounded native tool loop through `Call::Dispatch` and `Inference::ToolDispatcher`.
- OpenAI-compatible, Anthropic-compatible, and native API tool declarations now use provider-neutral native tool definitions.
- Embedding generation and discovery health checks now route through native `Call::Dispatch.dispatch_embed`.

## [0.8.46] - 2026-04-29

### Fixed
- Pipeline native dispatch now rejects tool-bearing requests that lack native tool-loop support instead of silently dropping tools.
- Escalation exhaustion now raises `EscalationExhausted` consistently when RubyLLM is unavailable, preserving the RubyLLM-absent native failure details in the error message.

## [0.8.45] - 2026-04-29

### Added
- Native LLM API now exposes model-offering inventory at `/api/llm/offerings` and provider-instance inventory at `/api/llm/instances`, matching the routing redesign metadata surface.

## [0.8.44] - 2026-04-28

### Fixed
- Native LLM API caller metadata now uses the unified `Legion::Identity::Request`/`Process` identity path instead of ad-hoc request waterfalls.
- Identity broker credential lookups now include `purpose:` and `context:` metadata so credential grants are auditable.
- Fleet request expiration no longer logs warnings for omitted or blank TTL values, and unified identity caller metadata accepts string-keyed `requested_by` hashes.

## [0.8.43] - 2026-04-28

### Changed
- RubyLLM is now loaded as an optional compatibility layer instead of a router runtime dependency, and native provider dispatch no longer falls back to RubyLLM by default.
- Non-pipeline chat, escalation, provider probes, startup defaults, discovery checks, and compatibility API tool builders now degrade cleanly when RubyLLM is unavailable, routing native direct calls where a registered native provider exists and raising `ProviderError` instead of `NameError` for RubyLLM-only paths.

## [0.8.42] - 2026-04-28

### Fixed
- LLM provider settings snapshots now initialize their fallback source before deep-copying settings, preventing an uninitialized local fallback when snapshot duplication raises.

## [0.8.41] - 2026-04-28

### Fixed
- The router gemspec now depends on the provider-neutral `lex-llm` base instead of installing legacy provider gems (`lex-bedrock`, `lex-claude`, `lex-gemini`, and `lex-openai`) as runtime dependencies.

## [0.8.40] - 2026-04-28

### Fixed
- Streaming inference now uses native lex-llm provider dispatch when the provider layer selects native mode.
- Startup discovery now refreshes local system facts independently of Ollama model refresh, and metering publish now loads its transport message class when connected instead of depending on prior boot order.

## [0.8.39] - 2026-04-28

### Fixed
- OpenAI-compatible, Anthropic-compatible, and native chat API routes now use the same server-resolved caller identity metadata as native inference, preserving audit and metering identity fields across compatibility routes.

## [0.8.38] - 2026-04-28

### Fixed
- `require 'legion/llm'` now loads `legion-settings` when the host has not already loaded `Legion::Settings`, preserving standalone settings defaults and override behavior during LegionIO load-phase initialization.

## [0.8.37] - 2026-04-28

### Fixed
- Router resolutions, health tracking, inventory, native dispatch, inference responses, audit, and metering now preserve optional lex-llm model offering metadata while keeping provider/model fallback behavior compatible with older callers.
- Inventory now consumes lex-llm 0.1.5 `ModelOffering`-style fields from configured settings or native provider adapters when available, exposing offering IDs, model families, canonical aliases, provider instances, and routing metadata without credentials.

## [0.8.36] - 2026-04-28

### Fixed
- Fleet transport now publishes requests through the `llm.fleet` exchange, keeps provider/model in fleet message bodies for workers, and publishes handler replies through the mandatory confirmed fleet response message path.
- Inventory now exposes exact offering lanes and non-secret offering metadata so provider instances can opt into offering-level routing without losing shared fleet lane compatibility.

## [0.8.35] - 2026-04-28

### Fixed
- Fleet lane routing now rejects sensitive or oversized public boundary, eligibility, and offering-instance segments before they can enter routing keys.
- Lex-llm native provider adapters now memoize provider instances and cover streaming, token-count estimation, provider failures, missing namespaces, and non-hash message inputs.
- Local Ollama/vLLM health probes now distinguish malformed base URL configuration from ordinary unreachable services.
- Inventory failures now re-raise programmer/config-shape errors instead of silently returning an empty model list.
- Fleet reply dispatch logging now includes operation tags, JSON parse failures are logged at warning level, and unwired broker return/nack helpers were removed so pending replies rely on the documented timeout path.
- The vLLM thinking patch now rescues only expected settings-shape errors instead of swallowing all runtime failures.

## [0.8.34] - 2026-04-28

### Fixed
- Native lex-llm provider dispatch now preserves injected system instructions when routing through `LexLLMAdapter`.
- Lex-llm bridge configuration now normalizes OpenAI-compatible `/v1` base URLs for `vllm` and `openai` providers while preserving versioned non-OpenAI-compatible endpoints.

## [0.8.33] - 2026-04-27

### Fixed
- `legion-llm` can now bridge loaded `lex-llm-*` provider classes into native dispatch through a `LexLLMAdapter`, allowing the new provider-gem split to participate without duplicating old `lex-*` runner constants.
- Provider-layer defaults now prefer `auto` dispatch and include the new `ollama`, `vllm`, `anthropic`, `openai`, `gemini`, and `mlx` native provider names.
- Inventory now recognizes `mlx` as a local HTTP provider.
- Fleet dispatch now registers reply futures before publishing requests, consumes structured publish results, fails fast on unroutable/nacked/confirm-timeout publishes, and validates reply metadata before fulfilling pending requests.
- `FleetRequest` now opts out of live-request spooling, requires mandatory publish and publisher confirms by default, and includes reply routing fields in the worker payload.
- `FleetResponse` and `FleetError` now publish live replies with mandatory routing, publisher confirms, and no spool/replay.
- LLM transport message IDs are memoized per message instance so AMQP return/confirm correlation sees the same `message_id` that was published.
- Embedding provider/model resolution, provider disable gates, prefix injection, fallback chains, Azure settings, Ollama base URLs, and metering caller context now honor JSON/string-keyed settings in addition to symbol-keyed runtime settings.
- Discovery for Ollama, vLLM, and embedding fallback chains now honors JSON/string-keyed provider, embedding, base URL, model metadata, and refresh TTL settings.
- Inference executor routing defaults, conversation compaction, pipeline escalation, native dispatch, async post-step, telemetry span, tool-loop, and fallback-provider settings now honor JSON/string-keyed settings.
- Module-level inference, prompt dispatch, prompt-cache, debate, and skill-injector settings now honor JSON/string-keyed settings.
- Sticky tool history, trigger matching, and RAG context settings now honor JSON/string-keyed settings.
- Shared settings helpers now normalize string and symbol keys across router, fleet, scheduling, response cache, API auth/defaults, metering, quality, guards, skills, discovery, inventory, daemon, config loaders, and audit checks.
- Shared settings helpers now register defaults through `Legion::Settings.merge_settings(:llm, ...)` and read directly from the canonical `Legion::Settings[:llm]` store so JSON-loaded settings files and runtime overrides remain authoritative.
- LLM cache, response-cache, and tool-confidence paths now prefer connected local cache backends while preserving shared cache fallback behavior.
- Boot, compatibility, Bedrock embedding, transport-connected, identity, RBAC, and API helper paths now use shared LLM settings/logging helpers instead of direct `Legion::Settings`, `Legion::Logging`, and `Legion::Cache` calls.
- LLM transport messages now promote tracing metadata into W3C `traceparent`, `baggage`, and Legion trace headers for fleet/audit/metering correlation.
- Fleet dispatch replies now avoid request-side metadata gates by default and expose both `model` and `model_id` so downstream metering and metadata readers can resolve the model consistently.
- Fleet lane sanitization and vLLM health URL normalization now avoid regex patterns flagged by CodeQL for uncontrolled input.
- The lex-llm provider bridge now loads only the Legion-native `Legion::Extensions::Llm` namespace and no longer probes removed fork-era entrypoints.

## [0.8.32] - 2026-04-27

### Fixed
- Embedding calls now return a clear unavailable-provider error when no embedding provider is configured or detected, preventing RubyLLM from implicitly selecting a chat/default provider.

## [0.8.31] - 2026-04-27

### Fixed
- Embedding calls no longer inherit the chat `llm.default_provider`, preventing vLLM or other chat defaults from receiving embedding traffic unless explicitly configured for embeddings. Fixes #104

## [0.8.30] - 2026-04-27

### Fixed
- Structured output parsing now strips markdown code fences before JSON parse, including retry responses from models that keep returning fenced JSON.
- LLM tool adapter dispatch now symbolizes JSON/string-keyed tool arguments before invoking Ruby keyword-argument tool classes.
- Default routing chains now honor explicit `default_provider` / `default_model` before auto-enabled local providers, preventing Ollama defaults from overriding a configured Bedrock default.
- Provider credential setup now resolves `env://` placeholders consistently for Bedrock SigV4, Anthropic, OpenAI, Gemini, Azure, and vLLM, and unresolved placeholder arrays no longer auto-enable hosted providers.
- Native `/api/llm/inference` responses now flatten structured provider content blocks into plain text for both streaming SSE deltas and non-streaming JSON responses, preventing Anthropic/Bedrock-style block arrays from being stored and replayed as nested JSON-looking assistant replies.
- Native `/api/llm/inference` streaming now emits `thinking-delta` SSE events for provider reasoning chunks without appending those chunks to final assistant content.
- Native `file_read` client tools now extract text from PDFs via `pdf-reader` and return a clear unsupported-binary message for non-text binary files.
- Local providers now cap automatically injected registry tools with `llm.tool_trigger.local_tool_limit`, prioritizing trigger-matched tools before always-loaded tools for Ollama/vLLM requests.

## [0.8.29] - 2026-04-27

### Added
- Bedrock embedding support via `call/bedrock_embeddings.rb` — a `RubyLLM::Providers::Bedrock` monkey-patch (same pattern as `bedrock_auth.rb`) that implements `render_embedding_payload`, `embedding_url`, `parse_embedding_response`, and overrides `embed` for signed transport. Covers Amazon Titan v1, Titan v2 (selectable 256/512/1024 dimensions), and Cohere Embed v3 (English + multilingual).
- Short-circuit guard: when ruby_llm eventually ships native `render_embedding_payload`, the patch becomes inert rather than double-loading the method.
- Trap-and-continue batch semantics for Titan (which is single-text-per-call): `embed_titan_batch` iterates client-side, preserves partial successes on mid-batch failures, logs the failure count via `RubyLLM.logger.warn`, and only raises when 100% of inputs fail.
- Input-size guards: Titan rejects >8k tokens with a billable 400 — we now raise a descriptive `RubyLLM::Error` at ≥45 000 bytes before the wire call. Cohere enforces the 96-texts / 8 KB-per-text documented limits.
- Full spec coverage in `spec/legion/llm/bedrock_embeddings_spec.rb` (probe contract, per-model payload shapes, dimension validation, batch limits, error paths).

### Fixed
- `Legion::LLM::Discovery.find_embedding_provider` can now actually resolve Bedrock when it is the configured fallback. Previously, the discovery probe (`klass.instance_method(:render_embedding_payload)`) raised `NameError` for Bedrock and the fallback chain skipped past it with `[llm][discovery] no embedding provider available` — even when Bedrock was the only reachable embedding provider.

## [0.8.28] - 2026-04-24

### Fixed
- Model/provider mismatch when clients send a model name (e.g., `qwen3.5:latest`) without an explicit provider. The routing paths blindly paired it with `default_provider` (typically `bedrock`), causing provider model lookup failures. Now infers the correct provider from model naming patterns before using the global default.
- `arbitrage_fallback` hardcoded `:cloud` tier and `:bedrock` provider when inference failed. Now uses `PROVIDER_TIER` to resolve the correct tier for the inferred provider.

### Added
- `Router.infer_provider_for_model(model)` — public method that maps model naming patterns to providers. Recognizes Ollama-style models (`:` or `/` in name), Bedrock (`us.*`), OpenAI (`gpt-*`, `o1-*`/`o3-*`/`o4-*`), Anthropic (`claude-*`), and Gemini (`gemini-*`).

## [0.8.27] - 2026-04-24

### Fixed
- vLLM provider sent `developer` message role (OpenAI convention) which Qwen's chat template rejects. Added `Vllm::Chat` module that overrides `format_messages` and `format_role` to always send `system`.
- vLLM provider called `OpenAI::Chat.render_payload` as a module function without provider instance context, causing `NoMethodError` on `openai_use_system_role`. Rewrote to use `super` with instance method overrides.
- Audit events included the full conversation history in every message — quadratic payload growth. Now caps at the last 20 messages (configurable via `compliance.audit_max_messages`). Full conversation reconstructable via `conversation_id`.

### Added
- vLLM `chat_template_kwargs` with `enable_thinking` sent on every request so vLLM separates reasoning into the `reasoning` response field instead of inline `<think>` tags.
- `providers.vllm.enable_thinking` setting (default: `true`). Controls whether thinking is enabled for vLLM requests. Per-request `thinking` param overrides.

## [0.8.26] - 2026-04-24

### Added
- First-class vLLM provider support. vLLM exposes an OpenAI-compatible API and is registered as a new RubyLLM provider (`:vllm`). Configured via `providers.vllm.base_url` in settings. Mapped to `:fleet` tier in the router.
- vLLM discovery via `/v1/models` endpoint. Caches model list with `max_model_len` (context window size) using the same TTL as Ollama discovery. Health checks via `/health` endpoint.
- Context overflow escalation: when vLLM rejects a request due to context length limits (32k on V100 hardware), the executor automatically falls back to cloud/frontier providers.

### Changed
- `find_fallback_provider` in `Executor` now skips all local providers (`:ollama` and `:vllm`) when searching for fallbacks, not just `:ollama`. Ensures context overflow escalates to cloud/frontier.
- `Router::PROVIDER_ORDER` updated: `:vllm` inserted after `:ollama` and before `:bedrock`.
- `default_provider_for_tier(:fleet)` returns `:vllm` when vLLM is enabled, falls back to `:ollama`.

## [0.8.25] - 2026-04-24

### Fixed
- `StructuredOutput.generate`, `handle_parse_error`, and `retry_with_instruction` used hash-style access (`result[:content]`, `result[:model]`) on the return value of `chat_single`, but `chat_single` returns a `RubyLLM::Message` object which only supports method access (`.content`, `.model_id`). All four access sites now use `respond_to?` duck-typing so both hash and Message objects work. Visible as `undefined method '[]' for an instance of RubyLLM::Message` in Apollo's `llm_detects_conflict?` and any structured output caller using non-schema-capable models (e.g. ollama/qwen).
- `Call::Embeddings.generate` crashed with `NoMethodError` on `.size` when `response.vectors` was a flat array (`[0.007, ...]`) instead of nested (`[[0.007, ...]]`). RubyLLM's OpenAI provider unwraps single-input embedding responses. Added `normalize_vectors_first` to detect and handle both flat and nested vector formats before dimension enforcement.

## [0.8.24] - 2026-04-23

### Fixed
- All AMQP transport messages (audit, metering, tool, escalation) now include identity headers (`x-legion-identity`, `x-legion-credential`, `x-legion-hostname`) extracted from the `caller` field. Previously only prompt audit events carried identity in the body — tool audit and metering messages had no identity at all.
- Embedding metering events now include `caller` context.
- Non-pipeline `chat_single` metering events now include `caller` context from kwargs.

## [0.8.23] - 2026-04-23

### Fixed
- `Call::StructuredOutput` parse-retry path passed `messages:` (plural) to `chat_single` which only accepts `message:` (singular), leaking the unknown kwarg into the provider chat call. Visible as repeated "unknown keyword: :messages" warnings during dream cycle contradiction detection. Flattened instruction + messages into a single string via `extract_user_content`.

## [0.8.22] - 2026-04-22

### Fixed
- Error paths in `Executor#run_provider_call_single` and `#step_provider_call_stream` now emit audit events (`Audit.emit_prompt`) before re-raising `RateLimitError`, `ProviderError`, and `ProviderDown`. Previously these errors produced no audit trail.
- Escalation exhaustion (`EscalationExhausted`) in the pipeline executor now emits an audit event with `status: 'escalation_exhausted'` before raising.
- `assert_external_allowed!` in the Inference module now emits an audit event with `status: 'privacy_blocked'` before raising `PrivacyModeError`, so enterprise privacy blocks are observable in the audit trail.
- `step_metering` in `Executor` now passes `request_id:` and `caller:` to `Steps::Metering.build_event` so every metering event carries caller identity and request correlation.
- `Steps::Metering.identity_fields` updated to include `request_id` and `caller` fields in the emitted metering event payload.
- `Call::Embeddings.generate` now emits a metering event via `Metering.emit` after each successful `RubyLLM.embed` call, covering the previously unmetered embedding path.
- `chat_single` in Inference now calls `emit_non_pipeline_metering` after a direct (non-pipeline) `session.ask` so token usage is recorded when the pipeline is disabled.
- `Call::StructuredOutput.generate` now logs `info` on successful parse and `warn` on `JSON::ParserError` for observability.

## [0.8.21] - 2026-04-22

### Fixed
- Tool audit events are now published to `llm.audit` exchange via `Audit.emit_tools` after each tool execution completes. Previously `emit_tools` was defined but never called — the `llm.audit.tools` queue was always empty.
- Metering events now include `request_type: 'chat'` so the routing key is `metering.chat` instead of `metering.` (empty suffix).

## [0.8.20] - 2026-04-22

### Fixed
- `tool_trigger_defaults[:tool_limit]` raised from 10 to 25. The v0.8.19 reduction from 50→10 was too aggressive — extension tools (Teams, etc.) are only injected via trigger matching, and a limit of 10 crowded them out when multiple extensions matched.

## [0.8.19] - 2026-04-22

### Fixed
- `Skills::Base#emit_event` passed a positional Hash to `Legion::Events.emit(**payload)`, causing `ArgumentError` on every skill activation. Now uses keyword splat correctly.
- `file_edit` client tool crashed with `TypeError: no implicit conversion of nil into String` when the LLM passed nil `old_text`/`new_text`. Now returns an error message to the LLM instead of crashing.
- `tool_trigger_defaults[:tool_limit]` reduced from 50 to 10 to prevent trigger word matching from injecting dozens of unrelated extension tools on normal user messages.

## [0.8.18] - 2026-04-22

### Fixed
- API caller identity no longer hardcoded as `api:inference`. The inference route now resolves the actual user via `env['legion.principal']` (from Identity::Middleware), `Legion::Identity::Process` (LDAP/Kerberos), or OS username (with email domain stripped). Adds `username` and `hostname` to the `requested_by` hash in audit trails.

## [0.8.17] - 2026-04-22

### Added
- Audit events now include `system_prompt` (full text sent to provider), `injected_tools` (list of tool names injected), and `identity` (extracted user identity from caller).

### Fixed
- `tokens` field in audit events was serialized as a `#<data ...>` inspect string instead of a proper hash. Now calls `.to_h` on Data.define objects.
- `enrichments` in audit events now compacted: array values (e.g. GAIA valence history) reduced to their last element.
- `timeline` in audit events filtered to only provider, escalation, and tool execution events — diagnostic trace entries (tracing:init, rbac, context:stored, etc.) are stripped.

## [0.8.16] - 2026-04-22

### Fixed
- Provider bad-request and context-length errors now trigger the provider retry chain instead of bubbling up as unhandled 500s. Both `run_provider_call_single` and `step_provider_call_stream` retry on the next available provider before giving up.
- Resolved provider/model is now logged (`log.info`) in `step_routing` so provider errors can be diagnosed from daemon logs without relying on SSE done events.

### Changed
- Extracted `try_fallback_or_raise` helper from duplicated retry logic in both rescue chains, reducing the auth/bad-request/context-overflow fallback pattern to a single call each.

## [0.8.15] - 2026-04-22

### Changed
- **5-tier routing model**: restructured from 3 tiers (local/fleet/cloud) to 5 tiers (local/fleet/openai_compat/cloud/frontier). Anthropic and OpenAI are now `:frontier` (direct API); Bedrock, Azure, Gemini are `:cloud` (managed providers). New `:openai_compat` tier for user-configured OpenAI-spec gateways.
- `Resolution`: added `frontier?`, `openai_compat?`, and `external?` predicates.
- `TierAssigner`: `user:*` and critical/high priority requests route to `:frontier` instead of `:cloud`.
- `GatewayInterceptor`: intercepts both `:cloud` and `:frontier` tiers, preserving original tier.
- Privacy enforcement (`assert_external_allowed!`) blocks all external tiers (cloud + frontier + openai_compat), not just cloud. `never_cloud` constraint now blocks both `:cloud` and `:frontier`. New `never_external` constraint blocks all three external tiers.
- `resolve_chain` fallback defaults changed from `:cloud`/`:bedrock` to `:frontier`/`:anthropic`.

## [0.8.13] - 2026-04-22

### Fixed
- Escalation loop now feeds `Router.health_tracker` with an `:error` signal on every failure so the circuit breaker trips when a provider is consistently down — auth failures, rate limits, and general errors all count.
- `AuthError` and `PrivacyModeError` in escalation are logged with `handled: true` so they appear in logs as gracefully-handled failures rather than uncaught exceptions.
- `RateLimitError` in escalation is handled the same way (was previously re-raised, aborting the entire chain).
- Extracted `attempt_escalation` and `record_escalation_failure` from `run_provider_call_with_escalation` to keep the method within Rubocop length limits and make each responsibility clear.

### Changed
- `CodexConfigLoader`: refactored to extract `read_config` helper (eliminates duplicate file-exist checks in `load` and `read_token`); added `read_openai_api_key` and `read_openai_credential` accessors for the multi-source credential probing chain.

## [0.8.12] - 2026-04-22

### Changed
- `ClaudeConfigLoader`: `settings_path` and `config_path` are now read from `Legion::LLM.settings.dig(:claude_cli, ...)` instead of hardcoded constants, making both paths configurable. `SECRET_URI_PATTERN` remains a constant — it's a protocol definition, not a runtime knob. Corresponding settings keys added to `Legion::LLM::Settings.claude_cli_defaults`.

## [0.8.11] - 2026-04-22

### Added
- Multi-source credential detection for all providers: `credential_available_for?` checks resolved env vars, not raw `env://` URI strings, so providers aren't falsely auto-enabled when the env var is unset.
- `probe_provider_credentials`: when multiple API keys exist for a provider (e.g. both `OPENAI_API_KEY` and `CODEX_API_KEY`), each candidate is tested in order and the first working key is committed; provider is disabled if all fail.
- `probe_via_model_list`: uses `RubyLLM::Provider.list_models` (a cheap GET with no token cost) to validate credentials before falling back to a lightweight chat probe.
- `recover_openai_with_codex`: automatically attempts Codex bearer-token fallback when all direct OpenAI keys fail.

### Fixed
- `configure_bedrock`/`configure_anthropic`/`configure_openai`: use `resolve_setting_reference` to unwrap `env://` placeholders before passing to RubyLLM config, preventing "key not found" errors when env var is absent.
- `ClaudeConfigLoader.apply_api_keys`: removed early-return pattern that prevented Bedrock bearer token import from running when no OpenAI key was found.

## [0.8.10] - 2026-04-22

### Changed
- `compliance_defaults`: `classification_scan` and `encrypt_audit` default to `false`; classification is opt-in, audit encryption is opt-in.
- `tool_trigger_defaults`: `scan_depth` raised to `10` (was `2`), `tool_limit` raised to `50` (was `10`).
- `trigger_match.rb`: hardcoded `|| 2` fallback updated to `|| 10` to match new setting default.

## [0.8.9] - 2026-04-22

### Fixed
- Classification spec: wholesale `Legion::Settings[:llm] = {...}` replacements converted to key-level writes (`[:llm][:default_provider] = :x`) to prevent wiping sibling settings.
- Audit `encrypt?` specs: updated to test toggle behavior (`false` by default, `true` when `encrypt_audit` setting is enabled) instead of expecting always-on.
- Trigger match spec: updated scan_depth expectation and before-block to match new defaults.

## [0.8.8] - 2026-04-22

### Changed
- `Legion::LLM.settings` now calls `Legion::Settings[:llm]` directly — dead `const_defined?('Settings')` branch and `Settings.default` fallback removed. No explicit `require 'legion/settings'` is needed in `llm.rb` because `legion-settings` is a gemspec dependency and is always activated by Bundler before `legion-llm` is required.
- `settings.rb` bootstrap call simplified from a guarded `begin/rescue` block to a direct `Legion::Settings.merge_settings(...)` call for the same reason.

## [0.8.7] - 2026-04-22

### Changed
- Eliminated scattered constants and duplicate settings files across the codebase:
  - `Skills::Settings` module deleted — defaults moved into `Legion::LLM::Settings.skills_defaults`; `Skills.start` no longer calls `Settings.apply` (merge happens at load time via the standard settings bootstrap)
  - `Fleet::Dispatcher` `DEFAULT_TIMEOUT`/`TIMEOUTS` constants removed — `resolve_timeout` now reads directly from `Legion::LLM.settings.dig(:routing, :tiers, :fleet, :timeouts, ...)`; dead `defined?(Legion::Settings)` guard removed
  - `Call::Embeddings` `PROVIDER_EMBEDDING_MODELS`, `TARGET_DIMENSION`, `OLLAMA_CONTEXT_CHARS`, `OLLAMA_DEFAULT_CONTEXT_CHARS`, `PREFIX_REGISTRY` constants removed — replaced with `target_dimension`/`embedding_settings` helpers reading from `settings[:embedding]`; `embedding_settings` corrected to use `Legion::LLM.settings` instead of bare `Legion::Settings.dig(:llm, :embedding)`
  - `Cache::Response` `DEFAULT_TTL`, `SPOOL_THRESHOLD`, `SPOOL_DIR` constants removed — replaced with private `default_ttl`/`spool_threshold`/`spool_dir` helpers reading from `settings[:prompt_caching][:response_cache]`
- `Settings.embedding_defaults` expanded: added `anthropic`/`gemini` to `provider_models`, added `ollama_context_chars`, `ollama_default_context_chars`, `prefix_registry`
- `Settings.prompt_caching_defaults.response_cache` gains `spool_threshold_bytes: 8MB`

## [0.8.6] - 2026-04-22

### Changed
- `Legion::LLM::Settings` is now the canonical module — content moved from `Legion::LLM::Config::Settings` directly into `lib/legion/llm/settings.rb`. The `Config::Settings` indirection and `lib/legion/llm/config/settings.rb` are removed. `service.rb` and any external callers using `Legion::LLM::Settings.default` continue to work unchanged.

## [0.8.5] - 2026-04-22

### Fixed
- All compliance settings now have explicit defaults defined in `Config::Settings.compliance_defaults` (merged under `llm.compliance`): `classification_scan`, `encrypt_audit`, `phi_block_cloud`, `cloud_providers`, `redact_pii`, `redaction_placeholder`, `strict_hipaa`, `default_level`. Previously these keys were read via `dig` with no guaranteed defaults.
- `Steps::Classification` now reads compliance settings via `Legion::LLM.settings.dig(:compliance, ...)` (consistent with all other llm settings) instead of bare `Legion::Settings.dig(:compliance, ...)` which targeted the wrong path.
- Removed dead `defined?(Legion::Settings)` guards in `Steps::Classification` — `legion-settings` is a hard dependency and is always present.

## [0.8.4] - 2026-04-22

### Fixed
- `Inference::Executor` now normalizes content-blocks arrays (`[{type: "text", text: "..."}]`) to a plain string before passing to `session.ask`. Previously the raw array was forwarded to RubyLLM, which serialized it as `{ type: 'text', text: [{...}] }` — an invalid Anthropic API payload causing HTTP 400 on every request when the Interlink sends structured content blocks.

### Added
- Audit encryption is now configurable: set `llm.compliance.encrypt_audit: true` in settings to encrypt payloads on the `llm.audit` exchange. Defaults to `false` (plaintext). Applies to `PromptEvent`, `ToolEvent`, and `SkillEvent`.

## [0.8.3] - 2026-04-22

### Fixed
- `EscalationEvent#routing_key` was called as a class-level DSL on load, raising `NoMethodError` and preventing `LLM::Transport.load_all` from completing. Converted to instance method to match all other message classes.
- Spec stub for `Legion::Transport::Message` also used the class-level DSL pattern, masking this bug. Updated to instance method.

## [0.8.2] - 2026-04-22

### Fixed
- `Escalation` exchange used class-level `exchange_name`/`exchange_type` DSL which doesn't exist on `Legion::Transport::Exchange`, raising `NoMethodError` at require time. Converted to instance methods `exchange_name` / `default_type`.
- `Legion::Settings[:llm][:connected]` writes were hitting an ephemeral overlay-merged hash copy; switched to `Legion::Settings.loader.settings[:llm][:connected]` to persist through restarts.

## [0.8.0] - 2026-04-21

### Changed
- BREAKING: Module hierarchy restructured — see compat.rb for full alias list
- Dead `lex-llm-gateway` references removed
- `hooks/metering.rb` + `hooks/cost_tracking.rb` collapsed into `Metering.install_hook`

### Added
- OpenAI-compatible API: POST /v1/chat/completions, GET /v1/models, POST /v1/embeddings
- Anthropic-compatible API: POST /v1/messages
- Config-driven /v1/ auth: settings[:llm][:api][:auth]
- Backward compat aliases via compat.rb with deprecation warnings

## [0.7.15] - 2026-04-20

### Added
- PHI cloud provider gate: `compliance.phi_block_cloud` (default: `false`) blocks restricted-classified requests from cloud providers when enabled. Warns on permit when disabled. Cloud provider list configurable via `compliance.cloud_providers`. Fixes #72

## [0.7.14] - 2026-04-20

### Added
- PII/PHI redaction mode: `compliance.redact_pii` (default: `false`) replaces detected patterns with configurable placeholder token before pipeline continues. Placeholder configurable via `compliance.redaction_placeholder` (default: `[REDACTED]`)
- `compliance.strict_hipaa` setting (default: `false`): when enabled, scans all 12 HIPAA patterns; when disabled, scans only core 3 (SSN, email, phone) for lighter processing. Closes #73

## [0.7.13] - 2026-04-20

### Fixed
- Classification step now always runs the PII/PHI scan, even on unclassified requests — defaults to `:public` baseline. Configurable via `compliance.default_level` (default: `:public`) and `compliance.classification_scan` (default: `true`). Fixes #70

## [0.7.12] - 2026-04-20

### Fixed
- RBAC step now respects `rbac.fail_open` setting (default: `true`) when `Legion::Rbac` is unavailable. Fleet callers are always blocked. Non-fleet callers are permitted with a warning when `fail_open` is true, or blocked with 503 when false. Fixes #69

## [0.7.11] - 2026-04-20

### Fixed
- RAG faithfulness check now logs a warning when RAG context is present but no `Hooks::RagGuard` is registered, instead of silently skipping. Fixes #71
- RAG faithfulness failure now logs at warn level in addition to appending to pipeline warnings array

## [0.7.10] - 2026-04-20

### Fixed
- `configure_anthropic` now passes `base_url` through to RubyLLM (`anthropic_api_base`) when present, enabling custom API gateways and proxies. Fixes #68
- `configure_openai` now passes `base_url` through to RubyLLM (`openai_api_base`) when present, for consistency with Anthropic and Ollama providers
- `configure_gemini` now passes `base_url` through to RubyLLM (`gemini_api_base`) when present, for consistency with Anthropic and Ollama providers

## [0.7.9] - 2026-04-18
### Added
- Expanded PII/PHI classification to cover 12 HIPAA Safe Harbor identifier patterns (was 3) and 20 PHI keywords (was 11). Partial fix for #73

### Fixed
- `web_fetch` client tool now delegates to `Legion::CLI::Chat::WebFetch.fetch` instead of bare `Net::HTTP.get` — gains SSL, redirect following, HTML-to-markdown conversion, and `maxLength` truncation (LegionIO/LegionIO#153)
- Added `web_search` client tool dispatch via `Legion::CLI::Chat::WebSearch.search` — previously fell through to generic "not executable server-side" error (LegionIO/LegionIO#154)

## [0.7.8] - 2026-04-17
### Fixed
- Guard `Embeddings.generate` against providers that don't support embeddings before calling `RubyLLM.embed` — prevents noisy `NoMethodError: undefined method 'render_embedding_payload'` warns when Bedrock (or Anthropic) is the active provider

## [0.7.7] - 2026-04-15

### Added
- Sticky runner tool injection: deferred tool runners stay injected for N human turns (trigger tier) or N deferred tool executions (execution tier) after activity, preventing the LLM from falling back to `legion_do` on follow-up messages
- Tool call history: every tool call is appended to a per-conversation enrichment block so the LLM can reference prior results (e.g. "the issue I created was #142")
- `Steps::StickyRunners`, `Steps::ToolHistory`, `Steps::StickyPersist` pipeline steps
- `ConversationStore#read_sticky_state` / `#write_sticky_state` for in-memory per-conversation state
- `Steps::StickyHelpers` shared settings helpers

## [0.7.6] - 2026-04-14

### Added
- `DaemonUnavailableError < LLMError` error class for fleet fail-closed semantics
- Metering wired as explicit pipeline executor step (`:metering` in STEPS)
- Router `exclude:` parameter — provider-keyed hash for anti-bias model exclusion (step 4.6 in `select_candidates`)
- `thinking:` forwarded to RubyLLM provider via `ruby_llm_chat_options`

### Fixed
- Tool injection suppression: `tools: []` (explicit empty array) now skips `inject_registry_tools` — prevents 60+ MCP tools from being injected into fleet LLM calls
- RBAC fail-closed for fleet: callers with `agent.id` starting with `fleet:` are blocked when RBAC is unavailable (scoped, does not affect non-fleet callers)
- `exclude:` normalized defensively — `nil` or non-Hash values treated as empty

## [0.7.5] - 2026-04-14

### Added
- `Legion::LLM::Prompt` module — clean API replacing `chat`/`ask`/`chat_direct` surface
  - `Prompt.dispatch(message, intent:, exclude:, tier:, tools:, ...)` — auto-routed via Router
  - `Prompt.request(message, provider:, model:, ...)` — pinned dispatch, full pipeline
  - `Prompt.summarize`, `Prompt.extract`, `Prompt.decide` — convenience methods (default `tools: []`)
  - Nil provider/model guard raises `LLMError` with actionable message
  - In-process pipeline execution (no DaemonClient HTTP roundtrip)
  - Backward compat: `Legion::LLM.chat` delegates to `Prompt.dispatch` for non-streaming calls
- `build_pipeline_request` uses `Pipeline::Request.from_chat_args` as base, preserving all pipeline kwargs

## [0.7.4] - 2026-04-14

### Fixed
- PHI/PII classification hard gate: `TierAssigner` now routes `contains_phi`/`contains_pii`/`:restricted` to `tier: :local` (fail closed). Previously routed to `:cloud`.

## [0.7.3] - 2026-04-13

### Added
- `system_baseline` setting — configurable default system prompt injected by `EnrichmentInjector` as the universal foundation layer for all pipeline-routed LLM calls; overridable via `Legion::Settings[:llm][:system_baseline]` or set to `nil` to disable
- `EnrichmentInjector.resolve_baseline` — reads `system_baseline` from settings and prepends it before GAIA advisory, RAG context, skills, and caller system prompt

### Fixed
- Replaced 11 bare `rescue StandardError` (swallowed exceptions) with `handle_exception` logging across `EnrichmentInjector`, `Skills`, `Skills::DiskLoader`, `Skills::ExternalDiscovery`, `ConversationStore`, `Pipeline::Executor`, and `Providers`

## [0.7.2] - 2026-04-13

### Fixed
- `transport_connected?` checks in audit, metering, fleet dispatcher, hooks/metering, and hooks/reflection all used `Legion::Transport.connected?` which does not exist at the module level — always returned `false`, silently dropping all AMQP publishes; replaced with canonical `Legion::Settings[:transport][:connected]` check (#61)

## [0.7.1] - 2026-04-13

### Fixed
- `Skills::Settings.apply` called undefined `[]=` on `Legion::Settings` module, raising `NoMethodError` that killed `LLM.start` before `@started` was set — caused all `/api/llm/inference` requests to 503 and all `llm_required?` extensions to be skipped (#60)
- Removed dead `defined?(Legion::Settings)` guard — `legion-settings` is a hard dependency
- Spec no longer relies on test-stub-only `[]=` that masked the production bug

## [0.7.0] - 2026-04-12

### Added
- `Legion::LLM::Skills` subsystem — first-class daemon-side skill execution
- `Legion::LLM::Skills::Base` — DSL base class with `skill_name`, `namespace`, `description`, `trigger_words`, `trigger`, `steps`, `follows`, `file_change_triggers`, `content` DSL
- `Legion::LLM::Skills::Registry` — thread-safe registry with `register`, `find`, `all`, `by_trigger`, `chain_for`, `reset!`, trigger word index, file trigger index, and cycle detection
- `Legion::LLM::Skills::StepResult` — result struct from individual skill steps (`inject:`, `gate:`, `metadata:`)
- `Legion::LLM::Skills::SkillRunResult` — aggregated result struct from a full skill run (`complete:`, `gated:`, `inject:`, `gate:`, `resume_at:`)
- `Legion::LLM::Skills::InvalidSkill` and `Legion::LLM::Skills::StepError` — typed skill validation and execution errors
- `Legion::LLM::Pipeline::Steps::SkillInjector` — pipeline step (step 10.5) that matches trigger words and file change patterns, activates matching skills, and injects results as `skill:active` enrichment
- `Legion::LLM::ConversationStore` skill state methods: `set_skill_state`, `skill_state`, `clear_skill_state` for resumable multi-turn skills
- `Legion::LLM::Audit::SkillEvent` — audit event for skill invocations

## [0.6.31] - 2026-04-10

### Fixed
- `ConversationStore#db_append_message` — coerce multi-part content blocks (arrays of `{type:, text:}` hashes) to plain string before Sequel insert, preventing `PG::UndefinedColumn` errors
- `ConversationStore#next_seq` — fall back to DB max seq when in-memory message list is empty, preventing seq collisions after eviction or restart

## [0.6.30] - 2026-04-10

### Added
- `Legion::LLM::Pipeline::Steps::TriggerMatch` — pipeline step that matches recent message words against `Legion::Tools::TriggerIndex` and populates `@triggered_tools`
- `tool_trigger` settings defaults (`scan_depth: 2`, `tool_limit: 10`) in `Legion::LLM::Settings`
- Trigger-matched tools are injected into the RubyLLM session in `inject_registry_tools` after always-loaded tools
- `:trigger_match` step inserted between `:rag_context` and `:tool_discovery` in `STEPS` and `PRE_PROVIDER_STEPS`
- `:trigger_match` added to all profile skip lists that skip `:tool_discovery` (`GAIA_SKIP`, `SYSTEM_SKIP`, `QUICK_REPLY_SKIP`, `SERVICE_SKIP`)

## [0.6.29] - 2026-04-09

### Changed
- `PythonVenv::VENV_DIR` reads `LEGION_PYTHON_VENV` env var first, falls back to `~/.legionio/python`

## [0.6.28] - 2026-04-09

### Added
- `Legion::LLM::Tools::Interceptor` — extensible tool call interception registry
- `Legion::LLM::Tools::Interceptors::PythonVenv` — rewrites `python3`/`pip3` commands to Legion-managed venv when available
- ToolAdapter#execute calls Interceptor.intercept before dispatching to tool class
- Interceptors loaded automatically during `Legion::LLM.start`

## [0.6.26] - 2026-04-09

### Changed
- Canonical exchange location is now `Legion::LLM::Transport::Exchanges::Metering` and `::Audit`
- `Legion::LLM::Metering::Exchange` and `Legion::LLM::Audit::Exchange` are now thin aliases for backwards compatibility
- `AuditEvent` and `EscalationEvent` inherit `Legion::LLM::Transport::Message` instead of `::Legion::Transport::Message`
- Event classes (`Metering::Event`, `Audit::PromptEvent`, `Audit::ToolEvent`) reference `Transport::Exchanges::*`

## [0.6.25] - 2026-04-08

### Added
- `Legion::LLM::Transport::Message` — LLM base message class with `message_context` propagation, LLM-specific headers (`x-legion-llm-provider`, `x-legion-llm-model`, `x-legion-llm-request-type`, `x-legion-llm-schema-version`), context header promotion, and `tracing_headers` stub for future OpenTelemetry integration
- `Legion::LLM::Fleet::Exchange` — declares `llm.request` topic exchange (source of truth for fleet routing)
- `Legion::LLM::Fleet::Request` — fleet inference request message with priority mapping, TTL-to-expiration conversion, and `req_` prefixed message IDs
- `Legion::LLM::Fleet::Response` — fleet inference response message with default-exchange publish override, Bunny error rescue, and `resp_` prefixed message IDs
- `Legion::LLM::Fleet::Error` — fleet error message with `ERROR_CODES` registry (12 codes), `x-legion-fleet-error` header, default-exchange publish override, and `err_` prefixed message IDs
- `Legion::LLM::Metering::Exchange` — declares `llm.metering` topic exchange
- `Legion::LLM::Metering::Event` — metering event message with tier header, `metering.<type>` routing keys, and `meter_` prefixed message IDs
- `Legion::LLM::Metering` module — `emit(event)` and `flush_spool` public API replacing gateway dependency for metering
- `Legion::LLM::Audit::Exchange` — declares `llm.audit` topic exchange (supersedes `Transport::Exchanges::Audit`)
- `Legion::LLM::Audit::PromptEvent` — prompt audit message (always encrypted) with classification, caller, retention, and tier headers
- `Legion::LLM::Audit::ToolEvent` — tool call audit message (always encrypted) with tool metadata headers
- `Legion::LLM::Audit` module — `emit_prompt(event)` and `emit_tools(event)` public API (no spool — audit data too sensitive for plaintext disk)
- `Fleet::Dispatcher.build_routing_key` — builds `llm.request.<provider>.<type>.<model>` routing keys with `:` to `.` sanitization
- `Fleet::Dispatcher` per-type timeout resolution (`embed: 10s`, `chat: 30s`, `generate: 30s`) from settings or `TIMEOUTS` constant
- `Fleet::Dispatcher` backwards-compatible shim supporting both old `(model:, messages:)` and new `(request:, message_context:)` dispatch signatures
- `Fleet::ReplyDispatcher.fulfill_return` — handles `basic.return` with `no_fleet_queue` error
- `Fleet::ReplyDispatcher.fulfill_nack` — handles `basic.nack` with `fleet_backpressure` error
- `Fleet::ReplyDispatcher` type-aware delivery dispatch — handles `llm.fleet.response`, `llm.fleet.error`, and legacy (no type) formats
- `routing.tier_priority` setting — default `[local, fleet, direct]` three-tier ordering
- `routing.tiers.fleet.timeouts` setting — per-request-type timeout configuration

### Changed
- `Fleet::Dispatcher#publish_request` now uses `Fleet::Request` message class (falls back to gateway `InferenceRequest` when `Fleet::Request` unavailable)
- `Pipeline::Steps::Metering#publish_event` now delegates to `Legion::LLM::Metering.emit` instead of `Gateway::Transport::Messages::MeteringEvent`
- `Pipeline::AuditPublisher#publish` now delegates to `Legion::LLM::Audit.emit_prompt` instead of raw `Transport::Messages::AuditEvent`
- `routing.tiers.fleet.queue` default changed from `llm.inference` to `llm.request` (fleet exchange rename)

## [0.6.24] - 2026-04-08

### Added
- `Legion::LLM::Patches::RubyLLMParallelTools`: monkey-patch that replaces RubyLLM's serial `handle_tool_calls` loop with concurrent thread execution so all tool calls in a batch run in parallel
- `ToolResultWrapper` struct exposes `tool_call_id`, `id`, `tool_name`, `result`, and `content` so bridge scripts can match results back to UI slots without falling back to name-based matching
- `emit_tool_result_event` in `Pipeline::Executor`: fires `tool_event_handler` with `type: :tool_result`, `duration_ms`, `started_at`, and `finished_at` after each tool completes
- `tool_event_handler` now also fires `type: :model_fallback` events (with `from_model`, `to_model`, `error`, `reason`) on auth-failed provider fallback in both regular and streaming paths
- `max_tool_rounds` setting (default `200`) in LLM settings; `install_tool_loop_guard` now reads it at call time so callers can override the cap per-session
- `started_at` timestamp stored in `Thread.current[:legion_current_tool_started_at]` for accurate per-call wall-clock duration even across parallel threads

### Changed
- Tool-loop round cap raised from `25` to `200` for the configurable `max_tool_rounds` setting.

### Fixed
- `ConversationStore#db_append_message` now serializes non-String `content` values (e.g., tool-call arrays) to JSON before writing to the database, preventing Sequel type errors when tool-use messages are persisted

## [0.6.23] - 2026-04-07

### Fixed
- `build_response_routing` now always sets `routing[:escalated]` (defaults to `false`) instead of conditionally omitting the key
- Schema spec annotations updated: Thinking, Cache, Config(Generation) corrected to reflect `from_chat_args` first-class field mapping; ErrorResponse annotation updated with complete error hierarchy including `EscalationExhausted`, `PrivacyModeError`, `TokenBudgetExceeded`, `DaemonDeniedError`, `DaemonRateLimitedError`

## [0.6.22] - 2026-04-07

### Fixed
- Classification LEVELS ordering: swapped `[:public, :internal, :restricted, :confidential]` to correct `[:public, :internal, :confidential, :restricted]` so severity comparisons work properly
- `Response.from_ruby_llm` now extracts actual `stop_reason` from provider response instead of hardcoding `:end_turn`
- `Request.from_chat_args` maps 16 fields (`tool_choice`, `generation`, `thinking`, `response_format`, `context_strategy`, `cache`, `fork`, `tokens`, `stop`, `modality`, `hooks`, `idempotency_key`, `ttl`, `metadata`, `enrichments`, `predictions`) to first-class struct members instead of dumping into `extra`
- `build_response` populates routing details (strategy, tier, escalation chain, latency), cost estimation via `CostEstimator`, and actual stop reason instead of hardcoded defaults
- `response_tool_calls` merges execution data (exchange_id, source, status, duration_ms, result) from timeline events into tool call hashes
- `step_conversation_uuid` now auto-generates `conv_<hex>` when no conversation_id is provided (was a no-op)
- `step_response_normalization` now normalizes all enrichment keys to string format (was a no-op)
- Enrichment key `[:conversation_history]` corrected to `['context:conversation_history']` for consistent `source:type` pattern

### Changed
- Schema spec (`docs/llm-schema-spec.md`) updated: ToolCall, Config(Generation), Cost, Routing(response), Stop status changed from Partial/Not-implemented to Implemented

## [0.6.21] - 2026-04-07

### Added
- Real-time tool call SSE streaming: tool-call, tool-result, and tool-error events emitted during execution, not after completion
- `ClientToolMethods` module extracted from inline tool class for cleaner separation
- Rich tool execution logging: command, path, pattern, url shown per tool type instead of just key names
- `summarize_tool_args` produces structured log details per tool type (sh, file_read, file_write, file_edit, grep, glob, web_fetch, list_directory)
- `tool_event_handler` callback on `Pipeline::Executor` for real-time tool event forwarding via `Thread.current`

### Fixed
- `install_tool_loop_guard` now uses `session.on_tool_call` instead of `session.on(:tool_call)` — RubyLLM callback was never firing, tool_call_id was always nil
- `list_directory` tool now expands `~` via `File.expand_path` — previously failed with `ENOENT` on tilde paths
- SSE text-delta events logged at debug level instead of info to reduce log noise

## [0.6.20] - 2026-04-06

### Added
- Per-step pipeline timing diagnostics: `[pipeline][timing]` log line with duration per step
- Pre-pipeline timing in inference route: `gaia_ingest`, `pre_pipeline_setup`, `executor_call` durations
- Tool-loop round cap (25) to prevent infinite cycling
- `install_tool_loop_guard` applied to both streaming and non-streaming provider paths

### Fixed
- fix Process namespace collision by using ::Process::CLOCK_MONOTONIC prefix inside Legion namespace

### Added
- `Legion::LLM::Pipeline::ToolAdapter` - wraps Tools::Base for RubyLLM sessions
- `Profile.derive` returns `:human` for `type: :human` and `type: :user` callers (Wire Format Phase 3)
- `Profile.derive` returns `:service` for `type: :service` callers (Wire Format Phase 3)
- `HUMAN_SKIP` constant (empty — humans get full pipeline)
- `SERVICE_SKIP` constant — services skip conversational steps (context, tools, knowledge)

### Changed
- Renamed `McpToolAdapter` to `ToolAdapter` (backwards compat alias kept)
- Pipeline step `McpDiscovery` renamed to `ToolDiscovery`
- Executor reads from `Legion::Tools::Registry`
- `chat_single` wraps registry tools with ToolAdapter
- Routes: executor handles all tool injection, routes only pass client tools

### Removed
- MCP server dependency for tool injection in routes

## [0.6.16] - 2026-04-03

### Fixed
- MCP tool adapter now correctly deserializes `MCP::Tool::Response` objects instead of returning raw `#<Response:0x...>` strings
- Removed `is_a?(Class)` guard in executor `inject_ruby_llm_tools` that silently dropped MCP adapter instances
- Added `cached_mcp_tools` to inference route with lazy caching (only persists when tools are available)

## [0.6.15] - 2026-04-03

### Changed
- Knowledge capture step (writeback + local ingest) now runs async in a background thread instead of blocking the pipeline response

## [0.6.14] - 2026-04-02

### Fixed
- Preserved fleet reply success and error state exactly as produced by the handler instead of forcing successful delivery metadata onto failures
- Preserved full fleet chat request fidelity by replaying prior messages locally and forwarding provider/model context through fleet chat, embed, and structured execution paths (closes #48)

## [0.6.13] - 2026-04-02

### Fixed
- Honored `llm.daemon.enabled` in `DaemonClient` so daemon-first behavior is fully disabled when operators turn the daemon off
- Honored nested `llm.routing.health.*` settings when building the router health tracker so custom health windows and circuit-breaker thresholds take effect (closes #45)

## [0.6.12] - 2026-04-02

### Fixed
- Fixed `Batch.flush` direct execution so grouped work preserves provider/model routing, executes the queued request, and bypasses scheduling deferral when draining the queue
- Fixed deferred `ask_direct` execution so direct asks enqueue the original message and return the deferred result cleanly instead of crashing on a deferred hash (closes #44)

## [0.6.11] - 2026-04-02

### Fixed
- Made response-cache spool overflow writes configurable via `llm.prompt_caching.response_cache.spool_dir` and updated the response-cache specs to use a hermetic temp directory instead of `~/.legionio`
- Updated README public API examples to match `Legion::LLM.ask(message: ...)` and to distinguish session creation from pipeline-backed `Legion::LLM.chat(message:/messages:)` calls (closes #46)

## [0.6.10] - 2026-04-02

### Changed
- Removed a redundant RuboCop block-length suppression in Sinatra route tool wiring after the `0.6.9` release cut

### Fixed
- Aligned streaming RubyLLM execution with the standard provider path so streamed requests now apply enriched system instructions and conversation breakpoints before provider execution, matching non-streaming prompt construction (closes #47)

## [0.6.9] - 2026-04-02

### Added
- Additional helper-based `info`/`error` logging across non-Sinatra runtime paths including native dispatch, prompt caching, GAIA caller helpers, billing and metering pipeline steps, provider and tool registries, compressor, reflection, shadow evaluation, and escalation tracking

### Changed
- Uplifted remaining non-Sinatra `lib/**/*.rb` runtime modules to `Legion::Logging::Helper`, replacing lingering wrapper-style `log_debug` calls with direct `log.debug/info/warn/error`
- Added catch-all `handle_exception` coverage for remaining non-Sinatra rescue paths, including RBAC pipeline failure handling
- Fixed pipeline request ID generation for `Request.from_chat_args` callers so response objects consistently retain a non-nil `request_id`
- Restored shared post-response tool-call serialization used by `PostResponse` and `KnowledgeCapture`, keeping audit publishing and local knowledge capture working in isolated step execution
- Guarded non-pipeline shadow-evaluation checks when `ShadowEval` is not loaded and cleared the remaining RuboCop regressions in `lib/` and route helpers

## [0.6.8] - 2026-04-01

### Added
- `ASYNC_SAFE_STEPS` constant and async dispatch for fire-and-forget post-provider pipeline steps (`post_response`, `knowledge_capture`, `response_return`) via a shared `Concurrent::FixedThreadPool` — frees Puma threads immediately after response normalization; `context_store` continues to run synchronously
- `pipeline_async_post_steps` setting (default `true`) controls sync vs async post-step dispatch
- Cached embed provider fallback chain at startup (`build_embedding_fallback_chain`, `provider_enabled?`) — stops re-probing on every embed failure
- Hard gate on disabled providers in `Embeddings.generate` and `generate_batch` — providers with `enabled: false` are never tried

### Changed
- `embedding_defaults[:provider_fallback]` no longer includes `azure` (leaked via `deep_merge` array concat)
- `find_fallback_provider` walks the cached startup chain instead of re-probing live

## [0.6.7] - 2026-04-01

### Added
- `PostResponse` pipeline step now calls `Legion::Gaia::AuditObserver.instance.process_event(audit_event)` after publishing the audit event, enabling GAIA partner awareness from LLM pipeline completions (guarded with `defined?` since legion-gaia is optional)

### Changed
- `gateway_defaults`: `enabled` changed from `false` to `true` — gateway is now on by default
- `prompt_caching_defaults`: `enabled` changed from `false` to `true` — prompt caching is now on by default

## [0.6.6] - 2026-04-01

### Added
- `McpToolAdapter` — wraps MCP server tool classes as RubyLLM::Tool instances for LLM session injection
- Pipeline `McpDiscovery` step discovers both server-side (Legion::MCP::Server) and client-side (MCP::Client::Pool) tools
- Tool name sanitization: dots replaced with underscores for Bedrock compatibility (`[a-zA-Z0-9_-]+`)

### Fixed
- Skip RubyLLM-based embedding health check for Azure provider since it uses direct HTTP with SNI host injection

## [0.6.5] - 2026-04-01

### Fixed
- Skip RubyLLM-based embedding health check for Azure provider since it uses direct HTTP with SNI host injection

## [0.6.4] - 2026-04-01

### Added
- Direct Azure OpenAI embedding provider with SNI host header injection, bypasses ruby_llm and DNS — connects to private endpoint IP with correct Host header
- Azure embedding supports single and batch requests, dimension enforcement, and settings-driven IP override (`llm.embedding.azure.ip`)
- Default embedding fallback chain: azure -> ollama -> bedrock -> openai

## [0.6.3] - 2026-03-31

### Changed
- Daemon defaults to `url: http://127.0.0.1:4567` and `enabled: true` so `legion chat` works out of the box

## [0.6.2] - 2026-03-31

### Fixed
- Reduce `OLLAMA_CONTEXT_CHARS` from 2048 to 1400 for 512-token models (mxbai-embed-large, bge-large, snowflake-arctic-embed) to account for real tokenization ratios (~3 chars/token)
- `generate_ollama` now catches context-length rejections and retries with chunking at 60% char limit instead of failing over to a potentially broken provider

## [0.6.1] - 2026-03-31

### Added
- Advisory step reads calibration_weights from Apollo Local, includes in advisory enrichment
- Advisory meta recording: classifies advisory types and calls `Legion::Gaia.record_advisory_meta`
- Advisory type classification based on partner context (tone, verbosity, format, context, hint)

## [0.6.0] - 2026-03-31

### Added
- `Legion::LLM::ProviderRegistry` — thread-safe registry for native lex-* provider extensions: `register(name, ext)`, `for(name)`, `available`, `registered?(name)`, `reset!`; cleared automatically on `Legion::LLM.shutdown` (closes #37)
- `Legion::LLM::NativeDispatch` — native provider dispatch layer: `dispatch_chat`, `dispatch_embed`, `dispatch_stream`, `dispatch_count_tokens` route calls to registered lex-* extension modules and return standardized `{ result:, usage: Usage }` hashes; raises `ProviderError` when provider is not registered (closes #37)
- `Legion::LLM::NativeResponseAdapter` — adapter wrapping native dispatch result hash to expose the same `.content`, `.input_tokens`, `.output_tokens`, `.usage` interface as a RubyLLM response object (closes #37)
- `provider_layer` settings section: `mode` (`'native'` / `'auto'`) and `native_providers` (default `['claude', 'bedrock']`) for native provider dispatch (closes #37)
- Auto-registration in `Legion::LLM.start`: detects loaded lex-* extensions via `Object.const_defined?` and registers them — `lex-claude` → `:claude`/`:anthropic`, `lex-bedrock` → `:bedrock`, `lex-openai` → `:openai`, `lex-gemini` → `:gemini`; no hard dependencies added (closes #37)
- `Pipeline::Executor` provider layer integration: `use_native_dispatch?` checks `provider_layer.mode`; `execute_provider_request_native` calls `NativeDispatch.dispatch_chat` and wraps result in `NativeResponseAdapter` (closes #37)
- Optional adversarial debate pipeline step for high-stakes decisions (closes #28): `Pipeline::Steps::Debate` runs a multi-round advocate/challenger/judge debate after `provider_call`; the initial response is the advocate, a challenger model critiques it, the advocate rebuts, and a judge model synthesizes all sides into the final response; activation via `debate: true` in `chat()` kwargs, or `Legion::Settings[:llm][:debate][:enabled]`, or GAIA auto-trigger when `gaia_auto_trigger: true` and `high_stakes`/`debate_recommended` are set in the advisory enrichment; debate is disabled by default; GAIA auto-trigger defaults to false in v0.6.0; different models are required for each role (advocate, challenger, judge) to avoid training bias — model rotation picks from enabled providers automatically when not explicitly configured; model strings use `provider:model` format; all LLM calls use `chat_direct` to avoid pipeline recursion; configurable via `debate.default_rounds` (default 1), `debate.max_rounds` (cap, default 3), `debate.advocate_model`, `debate.challenger_model`, `debate.judge_model`, `debate.model_selection_strategy` (default `'rotate'`); debate metadata (`enabled`, `rounds`, `advocate_model`, `challenger_model`, `judge_model`, `advocate_summary`, `challenger_summary`, `judge_confidence`) stored in `enrichments['debate:result']`; gracefully degrades to single-model mode with a warning when fewer than 2 models are available
- Async context curation (`Legion::LLM::ContextCurator`): keeps LLM context lean without compaction (closes #38). Heuristic curation runs async in `Thread.new` after each `step_context_store` — zero latency impact. Curated messages are used in `step_context_load` when available, falling back to raw history. Heuristic pipeline: `strip_thinking` removes `<thinking>` blocks; `distill_tool_result` summarizes large tool outputs by tool type (`read_file` → line count + first/last, `search`/`grep` → match counts, `bash` → exit code + last lines, default → char count + preview); `fold_resolved_exchanges` detects multi-turn clarification reaching agreement and folds to a system note; `evict_superseded` keeps only the latest read of each file path; `dedup_similar` removes near-duplicate messages via Jaccard similarity (delegates to `Compressor.deduplicate_messages`). LLM-assisted mode is built but off by default (`llm_assisted: false`); when enabled with `mode: 'llm_assisted'`, a configurable small/fast model produces better summaries with automatic fallback to heuristic on any error. All behavior gated by `Legion::Settings[:llm][:context_curation]`: `enabled` (default `true`), `mode` (`'heuristic'`), `llm_assisted` (`false`), `llm_model` (`nil`), `tool_result_max_chars` (2000), `thinking_eviction` (`true`), `exchange_folding` (`true`), `superseded_eviction` (`true`), `dedup_enabled` (`true`), `dedup_threshold` (0.85), `target_context_tokens` (40000).
- Message chain architecture with parent links and sidechain support in `ConversationStore` (closes #39): every message now carries `id` (UUID), `parent_id`, `sidechain` (default `false`), `message_group_id`, and `agent_id` fields; `build_chain(conversation_id, include_sidechains: false)` reconstructs ordered message history from parent links with rooted-leaf selection, parallel sibling recovery via `message_group_id`, and orphan appending; `sidechain_messages(conversation_id, agent_id: nil)` queries background/subagent messages with optional agent filter; `branch(conversation_id, from_message_id:)` creates a new conversation by copying history up to the given message; `store_metadata` / `read_metadata` provide tail-window session metadata storage; `migrate_parent_links!` backfills parent links on pre-migration sequential data; `messages()` backward-compatible flat array uses chain reconstruction when parent links are present, seq ordering otherwise; DB persistence adds `message_id`, `parent_id`, `sidechain`, `message_group_id`, `agent_id` columns when present (graceful degradation without migration)
- Per-pipeline-step OTEL child spans for distributed tracing (closes #21): `Pipeline::Steps::SpanAnnotator` maps step audit/enrichment data to OTEL span attributes (`rbac.outcome`, `classification.pii_detected`, `billing.estimated_cost_usd`, `rag.entry_count`, `routing.strategy`, `gen_ai.usage.input_tokens`, `confidence.score`, etc.); `Pipeline::Executor#execute_step` wraps each step in a `Legion::Telemetry.with_span("pipeline.<name>", kind: :internal)` child span; `annotate_top_level_span` sets `legion.pipeline.steps_executed`, `legion.pipeline.steps_skipped`, and `gen_ai.usage.cost_usd` on the top-level span after all steps complete; all wrapping gracefully no-ops when `Legion::Telemetry` is not defined or `enabled?` returns false, or when `telemetry.pipeline_spans` is set to `false`; telemetry errors never crash the pipeline
- Proactive model tier routing by task role and caller context (`Pipeline::Steps::TierAssigner`, step 8a): assigns routing tier before `step_routing` fires, based on GAIA routing hints, caller identity pattern matching (via `File.fnmatch?`), content classification (PHI/PII), and request priority; overrides are suppressed when the caller already sets an explicit `tier:`; default role mappings cover `gaia:tick:*`, `gaia:dream:*`, `system:guardrails`, `system:reflection`, and `user:*`; custom mappings configurable via `Legion::Settings[:llm][:routing][:tier_mappings]`; `step_routing` consumes the proactive assignment when no explicit caller intent is present (closes #22)
- `:quick_reply` pipeline profile for latency-sensitive conversational turns — skips 12 non-essential steps (idempotency, conversation_uuid, context_load, classification, gaia_advisory, rag_context, mcp_discovery, confidence_scoring, tool_calls, context_store, post_response, knowledge_capture), retaining only the 8 steps required for a valid provider round-trip (closes #27)
- Conversation auto-summarization at token threshold: `Compressor.auto_compact` compacts history when estimated tokens exceed `conversation.summarize_threshold` (default 50,000); preserves the most recent N turns (`preserve_recent`, default 10); older turns are summarized via `Compressor.summarize_messages` with LLM or stopword fallback; `Compressor.estimate_tokens` provides character-count/4 approximation; `ConversationStore.replace` atomically replaces in-memory history after compaction; wired into `Pipeline::Executor#step_context_load`; controlled by `conversation.auto_compact` (default `true`) (closes #26)
- `Legion::LLM::Usage` standard struct (`lib/legion/llm/usage.rb`): immutable `::Data.define` value object with `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, and `total_tokens` fields; `total_tokens` auto-calculated as `input + output` when not explicitly provided; all fields default to 0 (closes #35)
- Pipeline `extract_tokens` now returns a `Usage` struct instead of a plain hash when the provider response exposes token counts; populates `cache_read_tokens` and `cache_write_tokens` from response when available
- Asymmetric embedding prefix injection by task type: `generate` and `generate_batch` accept a `task:` keyword (`:document` or `:query`, default `:document`). `PREFIX_REGISTRY` maps model names to task-specific prefixes (`nomic-embed-text` gets `search_document:` / `search_query:`, `mxbai-embed-large` gets a query prefix). Prefix injection is controlled by `Legion::Settings.dig(:llm, :embedding, :prefix_injection)` (default `true`). Unknown models are passed through unchanged (closes #24).
- Prompt caching pipeline step (`Pipeline::Steps::PromptCache`): `apply_cache_control` marks the last system block with `cache_control: { type: 'ephemeral' }` when content exceeds `min_tokens * 4` chars; `sort_tools_deterministically` sorts tool schemas by name for stable cache keys; `apply_conversation_breakpoint` marks the last stable prior message with a cache breakpoint; all behavior gated behind `Legion::Settings.dig(:llm, :prompt_caching, :enabled)` (default: `false`); individual sub-features controlled by `cache_system_prompt`, `cache_tools`, `cache_conversation`, `sort_tools` flags; `scope` defaults to `'ephemeral'`; wired into `Pipeline::Executor#execute_provider_request` for system prompt and conversation history (closes #36)
- Escalation chain wired into `Pipeline::Executor#step_provider_call`: when `routing.escalation.enabled` and `pipeline_enabled` are both `true`, the provider call runs through the `EscalationChain` with per-attempt `QualityChecker` evaluation; non-retryable errors (`AuthError`, `RateLimitError`, `PrivacyModeError`) bubble up immediately; quality failures and transient errors advance to the next resolution in the chain; raises `EscalationExhausted` when all attempts are exhausted; timeline records an `escalation:attempt` event per try; `step_routing` populates `@escalation_chain` via `Router.resolve_chain` when escalation is enabled; `pipeline_enabled: true` added to `routing.escalation` defaults (closes #23).
- Token budget enforcement at the LLM call boundary (closes #25): `Legion::LLM::TokenTracker` thread-safe per-session accumulator (`record`, `total_tokens`, `session_exceeded?`, `session_warning?`, `reset!`, `summary`); `Pipeline::Steps::TokenBudget` pipeline step runs before `provider_call` — raises `TokenBudgetExceeded` when the estimated request input exceeds `max_input_tokens` (from `request.extra`) or the session total hits `session_max_tokens`; logs a warning at `session_warn_tokens`; `TokenBudgetExceeded` added to typed error hierarchy; token counts recorded automatically via `Pipeline::Steps::PostResponse#record_token_usage` after each successful provider call; budget settings under `Legion::Settings[:llm][:budget]`: `session_max_tokens` (nil = off), `session_warn_tokens` (nil = off), `daily_max_tokens` (nil = off, future enforcement).

## [0.5.24] - 2026-03-31

### Added
- `DaemonClient.inference` accepts optional `caller:` and `conversation_id:` kwargs, forwarded in POST body
- `/api/llm/inference` route accepts `caller` and `conversation_id` from POST body, forwards to `Legion::LLM.chat`

## [0.5.23] - 2026-03-31

### Added
- `Hooks::Reciprocity` — after_chat hook that records a `:given` social exchange event via `Social::Social::Client#record_exchange` when a caller with identity receives an LLM response; silently no-ops when social extension or identity is absent
- Partner context enrichment in `Pipeline::Steps::GaiaAdvisory` (step 7) — when the caller identity is registered as a partner in `Legion::Gaia::BondRegistry`, the advisory data is enriched with a `:partner_context` hash containing standing, compatibility, recent_sentiment, and interaction_pattern; sourced from Apollo Local `partner`-tagged entries with full graceful degradation when Apollo is unavailable

## [0.5.22] - 2026-03-31

### Added
- Auto-chunking for oversized Ollama embedding inputs via `lex-knowledge` Chunker with character-split fallback
- `average_vectors` for document-level embedding from multiple chunks
- Per-model Ollama context limits (`OLLAMA_CONTEXT_CHARS`): mxbai-embed-large 2048, nomic-embed-text 32768
- `lex-knowledge` added as a dependency for semantic chunking

### Fixed
- `handle_embed_failure` no longer permanently mutates `@embedding_provider` — failover is per-request only
- `ollama_preferred` order corrected: `mxbai-embed-large` (1024 dims) first, `nomic-embed-text` (768 dims) second

## [0.5.21] - 2026-03-31

### Added
- Provider health checks at boot: each SaaS provider is pinged with a test request; failures disable the provider with a log warning
- `resolve_llm_secrets` — resolves `env://` and `vault://` URIs in LLM settings before provider configuration (fixes late-loaded settings not being resolved)
- `CodexConfigLoader.read_token` — extracts valid Codex auth token for fallback credential recovery
- Credential recovery: when OpenAI fails health check, automatically tries `~/.codex/auth.json` token as fallback
- Provider summary log after health checks listing all available providers
- All-providers-down error log when no providers survive health checks
- Embedding health check for SaaS providers during boot (Ollama skipped — model-pulled check is sufficient)
- Direct Ollama embedding via `POST /api/embed` — bypasses RubyLLM which doesn't support Ollama embeddings
- Pipeline executor provider fallback: on auth/forbidden errors, automatically retries with next enabled provider
- `RubyLLM::Error` subclasses now caught in pipeline executor (previously only Faraday errors were rescued)

### Changed
- Bedrock default model corrected from `us.anthropic.claude-sonnet-4-6-v1` to `us.anthropic.claude-sonnet-4-6`
- Ollama default model changed from `llama3` to `qwen3.5:latest`
- `nomic-embed-text` added as first preference in `ollama_preferred` embedding models
- `Discovery::Ollama.model_available?` now uses prefix matching (`mxbai-embed-large` matches `mxbai-embed-large:latest`)
- Removed redundant `ping_provider` — replaced by `verify_providers` which checks all enabled SaaS providers
- `ModelNotFoundError` during health check no longer disables the provider (RubyLLM registry gap, not auth failure)

## [0.5.20] - 2026-03-30

### Added
- `CodexConfigLoader`: auto-imports OpenAI bearer token from `~/.codex/auth.json` when `auth_mode` is `chatgpt` and no existing OpenAI API key is configured (#15)
- JWT expiry validation — expired codex tokens are skipped with a debug log (#15)
- Non-JWT tokens (plain API keys) accepted without validation (#15)
- Falls back to vault/settings/env when codex auth file is absent or token is expired (#15)
- `Legion::LLM::Helper` module at `lib/legion/llm/helper.rb` — canonical helper following cache/transport pattern (#20)
- Layered defaults: `llm_default_model`, `llm_default_provider`, `llm_default_intent` (LEX-overridable) (#20)
- `llm_embed_batch` — batch embedding convenience (#20)
- `llm_structured` — structured JSON output convenience (#20)
- `llm_ask` — daemon-first single-shot convenience (#20)
- `llm_connected?` / `llm_can_embed?` / `llm_routing_enabled?` — status helpers (#20)
- `llm_cost_estimate` / `llm_cost_summary` / `llm_budget_remaining` — cost and budget helpers (#20)
- Layered model/provider/intent defaults applied to `llm_chat` and `llm_session` (#20)

### Changed
- `lib/legion/llm/helpers/llm.rb` is now a backward-compat shim that includes `Legion::LLM::Helper` (#20)

## [0.5.18] - 2026-03-29

### Fixed
- `Legion::LLM::Embeddings` now eagerly required at load time — previously lazy-required only inside `embed_direct`/`embed_batch`, causing `uninitialized constant Legion::LLM::Embeddings` when extensions (e.g. lex-apollo) referenced the constant directly

## [0.5.17] - 2026-03-28

### Added
- `Legion::LLM::ConfidenceScore` value object (`lib/legion/llm/confidence_score.rb`): immutable struct with `score` (Float 0.0–1.0), `band` (`:very_low/:low/:medium/:high/:very_high`), `source` (`:heuristic/:logprobs/:caller_provided`), and `signals` hash. `#at_least?(band)` for band comparison. `BAND_ORDER` constant for ordered band comparison.
- `Legion::LLM::ConfidenceScorer` module (`lib/legion/llm/confidence_scorer.rb`): computes `ConfidenceScore` from three strategy sources in priority order — (1) caller-provided score via `confidence_score:` option, (2) model-native logprobs (detected via `class.method_defined?(:logprobs)` to avoid test-double interference), (3) heuristic analysis (refusal, truncation, repetition, too_short, json_parse_failure, hedging language penalties; structured output bonus for valid JSON). Band boundaries are read from `Legion::Settings[:llm][:confidence][:bands]` at call time, per-call overrides accepted via `confidence_bands:` option.
- `Legion::LLM::Pipeline::Steps::ConfidenceScoring` module (`lib/legion/llm/pipeline/steps/confidence_scoring.rb`): new pipeline step `step_confidence_scoring` inserted after `response_normalization`. Reads `confidence_score:`, `confidence_bands:`, and `quality_threshold:` from `request.extra`; propagates `json_expected:` from `request.response_format`. Errors are soft-caught (appended to `@warnings`, step skipped).
- `confidence_defaults` settings method: band boundaries `{ low: 0.3, medium: 0.5, high: 0.7, very_high: 0.9 }` under `Legion::Settings[:llm][:confidence][:bands]`.
- `confidence_score` attr_reader on `Pipeline::Executor` for post-pipeline inspection.
- `quality:` field of `Pipeline::Response` is now populated with `@confidence_score.to_h` (score, band, source, signals).
- 54 new specs across `confidence_score_spec.rb`, `confidence_scorer_spec.rb`, `confidence_settings_spec.rb`, and `pipeline/steps/confidence_scoring_spec.rb`.

### Changed
- `Pipeline::Executor::STEPS` and `POST_PROVIDER_STEPS` now include `:confidence_scoring` after `:response_normalization`.
- `Legion::LLM.start` now requires `confidence_score` and `confidence_scorer` after `quality_checker`.

## [0.5.16] - 2026-03-28

### Fixed
- `POST /api/llm/inference` endpoint now routes through the 18-step pipeline when `pipeline_enabled?` is true — previously it created a bare `RubyLLM` session and called `session.ask` directly, bypassing RAG (step 8), GAIA advisory (step 7), knowledge capture (step 19), billing, and classification
- `POST /api/llm/chat` sync fallback path now routes through the pipeline (previously called `session.ask` on a bare session the same way)
- `_dispatch_chat` pipeline gate now fires when `messages:` array is present in addition to `message:` string — `Legion::LLM.chat(messages: [...])` was silently falling through to the legacy path even with `pipeline_enabled: true`
- `Pipeline::Executor#step_provider_call` and `#step_provider_call_stream` now inject prior messages via `session.add_message` before the final `ask` — multi-turn conversations passed as a `messages:` array now correctly preserve history at the provider level

### Added
- `spec/legion/llm/pipeline/executor_multi_turn_spec.rb`: specs verifying prior-message injection in single-turn, multi-turn, two-message, and streaming cases
- `spec/legion/llm/routes_inference_spec.rb`: specs verifying that `Legion::LLM.chat(messages: [...])` routes through the pipeline, carries tracing/timeline, handles multi-turn history, passes tool classes, and falls back gracefully when pipeline is disabled

## [0.5.15] - 2026-03-28

### Added
- `Legion::LLM::Routes` Sinatra extension module (`lib/legion/llm/routes.rb`): contains all `/api/llm/*` route definitions (chat, inference, providers) extracted from `LegionIO/lib/legion/api/llm.rb`. Self-registers with `Legion::API.register_library_routes('llm', Legion::LLM::Routes)` at the end of `Legion::LLM.start`.

### Changed
- `Legion::LLM.start` now calls `register_routes` after setting `@started = true`, mounting routes onto the API if `Legion::API` is available.

## [0.5.14] - 2026-03-27

### Added
- `CodexConfigLoader`: auto-imports OpenAI bearer token from `~/.codex/auth.json` when `auth_mode` is `chatgpt` and no existing OpenAI API key is configured
- JWT expiry validation — expired codex tokens are skipped with a debug log
- Non-JWT tokens (plain API keys) accepted without validation
- Falls back to vault/settings/env when codex auth file is absent or token is expired
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
- `Legion::LLM.ask` one-shot method: daemon-first routing with direct provider execution
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
