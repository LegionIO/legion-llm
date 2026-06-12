# P4b — Executor Decomposition + Embedding Pipeline (G19)

> **Branch:** `large-yolo-refactor`
> **Status:** DONE
> **Date:** 2026-06-11
> **Dependencies:** P4a (executor canonical, settings sweep, router consolidation)
> **Design:** `2026-06-09-nxn-canonical-routing-design.md` (R12 — extraction never shares a commit series with behavior change), `...-implementation.md` (Phase 4, G13, G19)
> **Sibling:** `P4a-executor-canonical.md`

---

## Suite Status

```
2964 examples, 0 failures
449 files inspected, no offenses detected
lib/legion/llm/inference/executor.rb: 1343 lines  (was 2862)
```

---

## Baseline (Start of P4b)

```
2939 examples, 0 failures
441 files inspected, no offenses detected
lib/legion/llm/inference/executor.rb: 2862 lines
```

WIP changes in working tree at start (kept untouched, behavior-fix patches owned outside P4b):
- `lib/legion/llm/api/namespaces/openai/responses.rb` — tool-call status `requires_action`
- `lib/legion/llm/call/lex_llm_adapter.rb` — tool_calls return as Array, not Hash
- their two specs

These are independent of decomposition and are not part of any P4b commit.

---

## Section 1 — Shared @ivar Inventory (R12 prerequisite)

> *"Before extraction, inventory shared @ivar state across candidate mixins — extraction without a state map is just spreading the coupling across files."* — design R12

`Executor#initialize` declares 36 ivars. Eight more are lazy-initialized inside methods (`@step_timing_hash`, `@extracted_tokens`, `@native_dispatch_tools`, `@native_tool_definitions`, `@cached_injected_system`, `@native_tool_loop_round`, `@last_tool_loop_messages`, `@tool_loop_messages`, `@last_escalation_error`, `@fallback_local_providers`, `@_response_*_snapshot`, `@raw_response`). The four planned mixins (Routing, Escalation, ContextWindow, ToolInjection) each have a distinct read/write footprint.

### 1.1 Functional-area map

| Area | Ivars **written** | Ivars **read (only)** |
|------|-------------------|-----------------------|
| **Routing** | `@resolved_provider`, `@resolved_instance`, `@resolved_model`, `@resolved_tier`, `@resolved_offering_id`, `@resolved_offering_metadata`, `@proactive_tier_assignment`, `@escalation_chain` (primary path), `@audit[:'routing:provider_selection']`, `@audit[:'routing:tier_assignment']`, `@warnings`, `@timestamps[:routing_start]`, `@exchange_id`, `@fallback_local_providers` (memoized), `@tool_event_handler` (only via `try_fallback_or_raise`) | `@request`, `@enrichments['gaia:routing_hint']`, `@enrichments['classification:scan']`, `@enrichments['context:conversation_history']`, `@triggered_tools`, `@timeline` |
| **Escalation** | `@escalation_chain`, `@escalation_history`, `@last_escalation_error`, `@current_escalation_context`, `@raw_response`, `@tool_loop_messages` (via provider call), `@last_tool_loop_messages`, `@audit` (escalation+error rows), `@warnings`, `@timestamps[:provider_start]`, `@timestamps[:provider_end]`, `@route_attempts` (via `RouteAttempts` mixin already extracted) | `@request`, `@resolved_provider`, `@resolved_instance`, `@resolved_model`, `@resolved_tier`, `@resolved_offering_id`, `@resolved_offering_metadata`, `@tracing`, `@exchange_id`, `@timeline`, `@extracted_tokens` |
| **ContextWindow** | (pure functional — operates on its argument `messages`, returns transformed array) | `@request.id`, `@resolved_offering_metadata` (via `resolved_context_window`) |
| **ToolInjection** | `@injected_tool_map`, `@native_tool_source_map`, `@cached_injected_system`, `@native_dispatch_tools` (memo), `@native_tool_definitions` (memo), `@warnings` | `@request`, `@enrichments`, `@native_tool_loop_round` (set by `NativeToolLoop` already-extracted module), `@triggered_tools`, `@resolved_offering_id`, `@resolved_offering_metadata`, `@resolved_provider` (via `local_provider?` shared with Routing) |

### 1.2 Shared-state contracts (the coupling that survives extraction)

These are the ivar interfaces the mixins must keep honoring after extraction. They are the surface area that any future "real" decomposition would have to formalize as method calls or value objects — for now, every mixin reads them through the shared `Executor` instance.

| Contract | Producer | Consumers |
|----------|----------|-----------|
| `@resolved_*` (provider/instance/model/tier/offering_id/offering_metadata) | `Routing#step_routing`, `Escalation#run_escalation_resolution`, `Routing#try_fallback_or_raise` | every mixin + main executor (build_response, metering, audit) |
| `@audit` (Hash by `:'category:key'`) | every step | `build_response`, `annotate_top_level_span`, `step_metering` |
| `@warnings` (Array<Hash\|String>) | every step that catches a non-fatal error | `build_response` |
| `@timeline` (`Inference::Timeline`) | every step that records an event | `build_response`, `step_metering`, span annotators |
| `@enrichments` (Hash<String, value>) | `Steps::RagContext`, `Steps::GaiaAdvisory`, `Steps::Classification`, `step_context_load`, `step_response_normalization` (renormalizes keys) | `Routing#routing_intent_for_request`, `ToolInjection#native_dispatch_options` (via `EnrichmentInjector`), `build_response_features` |
| `@timestamps` (Hash) | every phase boundary | `step_metering`, `record_provider_response`, `build_response` |
| `@raw_response` (`Canonical::Response`) | `Escalation#execute_provider_request*` | `Quality::Checker.check`, `extract_*`, `build_response`, `step_context_store` |
| `@tool_loop_messages` / `@last_tool_loop_messages` | `NativeToolLoop` mixin | `step_context_store#persist_tool_loop_messages`, `tool_loop_final_tool_calls` |
| `@escalation_chain`, `@escalation_history`, `@last_escalation_error` | Escalation | `build_response_routing`, `Escalation#skip_same_tier!`/`skip_all_provider_model_instances!` (read-after-write within the area) |
| `@injected_tool_map`, `@native_tool_source_map` | ToolInjection | `NativeToolLoop` (already-extracted) — looks up tool-class-by-name during dispatch |
| `@native_tool_loop_round` | `NativeToolLoop` (set on each loop iteration) | `ToolInjection#native_tool_loop_system`, `ToolInjection#native_dispatch_options` |
| `@pending_tool_history` (`Concurrent::Array`), `@pending_tool_history_mutex`, `@deferred_tool_audits` | tool emit/result event handlers (stay in `executor.rb`) | `flush_deferred_tool_audits`, `response_tool_calls` |

### 1.3 Initialization-order invariants

`initialize` is the single source for these ivars; mixins must NOT redefine `initialize`. Three ivars are lazy and *must remain lazy* after extraction (extraction would break behavior if the lazy guard moved):

- `@native_dispatch_tools` — `||=`-memoized; rebuilt on first call after `step_routing` resolves the provider, used inside the tool loop
- `@native_tool_definitions` — `||=`-memoized; same lifecycle
- `@cached_injected_system` — set inside `native_dispatch_options` only when `@native_tool_loop_round.to_i.positive?`; the round-zero branch always rebuilds the injected system fresh

The fallback-cache memo `@fallback_local_providers` uses a `defined?` guard to memoize an explicit `false`; extraction must preserve that pattern (truthy `||=` would forget a `false` decision).

### 1.4 Constants moving with their methods

| Constant | Stays/moves with |
|----------|------------------|
| `THINKING_TAG_PAIRS` | Stays in `executor.rb`; `ContextWindow#strip_leading_thinking_block` resolves it via lexical scope (the mixin is nested in `class Executor`, so module-method constant lookup walks `ContextWindow → Executor → Inference → LLM → Legion`). |
| `CONFIG_ERROR_PATTERNS` | Stays in `executor.rb`; same lexical-scope resolution from `Escalation#config_error?`. |
| `ToolResultEvent` (Struct) | stays in `executor.rb` (used by `dispatch_native_tool_call` in `NativeToolLoop` and event emitters) |
| `ASYNC_THREAD_POOL` | stays in `executor.rb` (used by `execute_post_provider_steps_mixed`) |
| `PRE_PROVIDER_STEPS`, `POST_PROVIDER_STEPS`, `STEPS`, `ASYNC_SAFE_STEPS` | stay in `executor.rb` (orchestrator) |

### 1.5 Method-to-mixin assignment (final)

**Routing → `inference/executor/routing.rb`** (478 lines): `normalize_offering_metadata`, `local_provider?`, `inferred_provider_tier`, `step_tier_assignment`, `step_routing`, `resolve_provider_instance`, `provider_scoped_instance`, `routing_request_state`, `estimate_request_tokens`, `routing_intent_present?`, `routing_intent_for_request`, `request_has_vision_content?`, `stream_routable_capability?`, `native_tools_requested_for_routing?`, `normalize_required_capabilities`, `apply_proactive_tier_assignment`, `resolve_model_to_local_provider`, `resolve_routing_state`, `routing_resolution_for`, `apply_routing_resolution`, `routing_field_explicit?`, `merge_routing_intent`, `record_forced_tier_selection`, `step_request_normalization`, `use_native_dispatch?`, `merge_response_offering_metadata`, `try_fallback_or_raise`, `find_fallback_provider`, `fallback_local_providers?`.

> Note: `registry_tool_limit` was originally listed under Routing in §1.5 but is consumed only by `add_settings_extensions_tool_definitions`. It stays in `executor.rb` (the host class) to avoid tying ToolInjection to a Routing dependency it does not otherwise need.

**Escalation → `inference/executor/escalation.rb`** (593 lines): `step_provider_call`, `run_provider_call_single`, `run_provider_call_with_escalation`, `run_escalation_resolution`, `escalation_move_type`, `attempt_escalation`, `report_escalation_quality_failure`, `record_escalation_failure`, `build_default_escalation_chain`, `skip_same_tier!`, `skip_all_provider_model_instances!`, `escalation_attempt_hash`, `pipeline_escalation_enabled?`, `pipeline_escalation_max_attempts`, `pipeline_escalation_quality_threshold`, `execute_provider_request`, `execute_provider_request_native`, `record_provider_response`, `report_provider_health`, `extract_retry_after`, `emit_error_audit`, `emit_escalation_attempt_audit`, `emit_escalation_attempt_metering`, `config_error?`, `context_overflow_error?`, `client_stream_error?`, `step_provider_call_stream`, `execute_provider_request_stream`, `execute_provider_request_stream_native`, `execute_provider_request_responses`.

**ContextWindow → `inference/executor/context_window.rb`** (163 lines): `native_dispatch_messages`, `enforce_context_window`, `compact_to_fit`, `resolved_context_window`, `estimate_message_tokens`, `strip_thinking_from_history`, `strip_leading_thinking_block`, `trim_oversized_tool_results`, `last_user_message_index`, `tool_result_message?`, `empty_assistant_message?`.

**ToolInjection → `inference/executor/tool_injection.rb`** (356 lines): `native_dispatch_options`, `native_tool_loop_system`, `native_tool_loop_continuation_prompt`, `native_dispatch_chat_options`, `native_dispatch_thinking`, `native_dispatch_tools`, `native_tool_definitions`, `registry_tool_injection_requested?`, `client_tool_passthrough_enabled?`, `client_tool_passthrough_allowed?`, `client_tool_passthrough_list`, `client_tool_passthrough_name_variants`, `client_tool_policy_variants`, `non_executable_client_tool?`, `add_pinned_special_tool_definitions`, `add_native_tool_definition`, `request_tool_source`, `resolve_registry_tool_source`, `request_tool_names`, `add_registry_tool_definitions`, `native_tool_definition_duplicate?`, `native_tool_definition_name_variants`, `add_settings_extensions_tool_definitions`, `add_requested_deferred_tool_definitions_from_settings`.

**Stays in `executor.rb`** — orchestration, response building, step dispatch, and the tool-call audit emission entwined with `@pending_tool_history` / `@pending_tool_history_mutex` / `@deferred_tool_audits`.

### 1.6 Streaming & audit-emission scope

The prompt named "streaming" and "audit emission" as functional areas to inventory, even though only four mixins are extracted in this pass.

- **Streaming.** `step_provider_call_stream`, `execute_provider_request_stream`, `execute_provider_request_stream_native`, `execute_provider_request_responses` move with **Escalation** (they share the same provider-call lifecycle and escalation entry/exit). `call_stream` itself stays in the orchestrator — it is the public entry the route layer calls.
- **Audit emission.** Splits along call-site boundaries: error/escalation audit emitters (`emit_error_audit`, `emit_escalation_attempt_audit`, `emit_escalation_attempt_metering`) move with **Escalation**; tool-call audit emitters (`emit_tool_call_event`, `emit_tool_result_event`, `publish_tool_audit`, `flush_deferred_tool_audits`, `spool_failed_tool_audit`) **stay in `executor.rb`** because they are entwined with the per-instance `@pending_tool_history` Concurrent::Array, the dedicated mutex, and the deferred-audit batch fan-out — moving them would either spread Concurrent::Array state across files or force the mixin to take the mutex from the executor instance, which adds coupling rather than reducing it.

### 1.7 Final size

| File | Before | After | Δ |
|------|-------:|------:|--:|
| `lib/legion/llm/inference/executor.rb`            | 2862 | 1343 | −1519 |
| `lib/legion/llm/inference/executor/routing.rb`         | — | 478  | +478 |
| `lib/legion/llm/inference/executor/escalation.rb`      | — | 593  | +593 |
| `lib/legion/llm/inference/executor/context_window.rb`  | — | 163  | +163 |
| `lib/legion/llm/inference/executor/tool_injection.rb`  | — | 356  | +356 |
| **Net executor surface (sum)**                       | 2862 | 2933 | +71 (module/include scaffolding) |

`executor.rb` is now **1343 lines**, above the ~600 stretch goal noted in the brief. The four-mixin scope cannot land below 600 without further extraction (response building, step dispatching, tool-call audit emission), which the brief did not request and which would tangle with `@pending_tool_history` Concurrent state. Reaching 600 is a follow-up — call it `Executor::Steps` / `Executor::ResponseBuilding` — that the inventory map already prepares for.

---

## Section 2 — Extraction commits (refactor-under-green)

| Mixin | Commit | executor.rb LOC | rspec | rubocop |
|-------|--------|----------------:|-------|---------|
| Routing       | `a6714ae` | 2862 → 2402 (−460) | 2939 examples / 0 failures | 442 / 0 offenses |
| Escalation    | `e5b1d1f` | 2402 → 1827 (−575) | 2939 / 0 | 443 / 0 |
| ContextWindow | `9fe1b7b` | 1827 → 1681 (−146) | 2939 / 0 | 444 / 0 |
| ToolInjection | `b384766` | 1681 → 1343 (−338) | 2939 / 0 | 445 / 0 |

Every commit was rspec-gated AND rubocop-gated before being accepted. No spec changed across the four refactor commits — proof the moves were behavior-preserving.

Of note: rubocop's `Metrics/ClassLength` `# rubocop:disable` comment on `class Executor` was auto-removed by `rubocop -A` after the Escalation extraction — the class no longer triggers the cop. Net positive: the disable comment is gone instead of being kept around for old reasons.

---

## Section 3 — G19 embedding pipeline

**Commit:** `c73bb0f`

### Shape

```
Legion::LLM.embed(text, **opts)
  └── Inference::EmbedPipeline.call(text:, model:, provider:, instance:, dimensions:, task:)
       ├── normalize_text(text)            # idempotent shape coercion
       ├── ContentHash.call(normalized)    # SHA-256 over normalized text
       ├── Cache.get("llm:embed:<model>:<dims>:<sha256>")
       │     ├── HIT  → Metering.emit(cost_usd: 0, cache_hit: true) → return cached vector
       │     └── MISS ↓
       ├── Call::Embeddings.generate(...)  # provider call
       ├── Metering.emit(cache_hit: false)
       └── Cache.set("llm:embed:<resolved_model>:<resolved_dims>:<sha256>", vector_payload, ttl:)
```

### Files

| Path | Purpose |
|------|---------|
| `lib/legion/llm/content_hash.rb`              | Shared SHA-256 utility (G19a). Audit ledger and embedding cache hash the same way, so records join across systems. |
| `lib/legion/llm/inference/embed_pipeline.rb`  | The pipeline above. `Legion::LLM.embed` delegates here. |
| `lib/legion/llm/inference/audit_publisher.rb` | `content_hash` now delegates to `Legion::LLM::ContentHash.call`. Byte-identical digests preserved (string-key precedence kept). |
| `lib/legion/llm/settings.rb`                  | New `embedding.cache.{enabled,ttl,key_prefix}` defaults under `embedding_defaults` per G13. |
| `lib/legion/llm.rb`                           | `embed` delegates through the pipeline; signature unchanged. |
| `spec/legion/llm/content_hash_spec.rb`        | 11 examples — determinism, message-array shape, string-key precedence, AuditPublisher digest compat. |
| `spec/legion/llm/inference/embed_pipeline_spec.rb` | 14 examples — miss / hit / disabled / error, canonical key format, metering shape on hit (`cost_usd: 0, cache_hit: true`). |

### Public-API contract

`Legion::LLM.embed(text, **opts)` keeps its public signature; opts (`model`, `provider`, `instance`, `dimensions`, `task`) flow through unchanged. Returns the same hash shape the underlying provider call returns (`vector`, `model`, `provider`, `dimensions`, `tokens`, `chunks`), plus `cache_hit: true` on a hit.

### Why the cache key includes (model, dims, sha256)

Vectors are deterministic per `(model, dims)` — a text-only key would collide across embedding spaces (`text-embedding-3-small` 1536-dim ≠ `mxbai-embed-large` 1024-dim). G19b made this explicit; the implementation reflects it.

### Why cache hits still emit metering

Per G19c, the highest-frequency LLM call type must not become a shadow-AI blind spot. Hits emit a metering event with `input_tokens: 0, output_tokens: 0, cost_usd: 0, cache_hit: true` so the ledger proves the cache savings rate with receipts.

### Pre-existing semantics preserved

- `embed_direct` / `emit_embed_metering` (deprecation warnings since v0.4.x) are untouched. Anyone calling `embed_direct` continues to bypass the pipeline as before — its eventual deletion is G16's job, not G19's.
- `embed_batch` still calls `Call::Embeddings.generate_batch` directly. Per-text caching of batch entries is a follow-up; the brief scoped G19 to single-text `embed`.

---

## Section 4 — Settings added (G13)

| Path | Default | Purpose |
|------|---------|---------|
| `llm.embedding.cache.enabled`    | `true`         | Master switch for embedding response cache |
| `llm.embedding.cache.ttl`        | `86_400` (sec) | Cache TTL — embeddings are deterministic per model so the default is long |
| `llm.embedding.cache.key_prefix` | `'llm:embed'`  | Cache key prefix (`<prefix>:<model>:<dims>:<sha256>`) |

All three live in `Settings#embedding_defaults` per G13 — no inline `||` defaults shadowing them.

---

## Section 5 — Final suite status

```
2964 examples, 0 failures   (+25 since baseline: 11 ContentHash + 14 EmbedPipeline)
449 files inspected, no offenses detected   (+8 files since baseline: 4 mixin lib/ + 2 G19 lib/ + 2 G19 spec/)
lib/legion/llm/inference/executor.rb: 1343 lines   (was 2862, −53%)
```

---

## Section 6 — Items the brief asked for, mapped to outcomes

| Brief requirement | Outcome |
|-------------------|---------|
| (1) Inventory shared @ivar state across executor functional areas — write the map into the report **first** | Done at Section 1 before any extraction. Inventory landed in `c73bb0f`'s ancestor commits as the report's first iteration. |
| (2) Extract verbatim into `inference/executor/{routing,escalation,context_window,tool_injection}.rb`, executor.rb under ~600 lines | Four extractions landed (`a6714ae`, `e5b1d1f`, `9fe1b7b`, `b384766`). Final 1343 lines — above the 600 target; §1.7 explains why and what a follow-up pass would carve out. |
| (3) Build the embedding pipeline per G19 (normalize → content hash → Legion::Cache → provider → metering → cache store) | `c73bb0f`. |
| Cache hits emit metering with `cost: 0, cache_hit: true` | Specs assert it. |
| Shared content-hash utility reused from `audit_publisher` | `Legion::LLM::ContentHash`; `audit_publisher#content_hash` delegates. |
| Settings `llm.embedding.cache.*` per G13 | Added under `embedding_defaults`. |
| `Legion::LLM.embed` keeps its public signature | Verified — same kwarg set, same return shape, `+ cache_hit: true` only on hits. |
| Full rspec after EVERY extraction step | Done — see §2 table. Zero spec changes across the four refactor commits. |
| rubocop clean per commit | Done — every commit is `0 offenses`. The auto-removed `ClassLength` disable comment is the only rubocop change. |
| Never force push, no Co-Authored-By, no company refs | Verified. Five new commits, fast-forwardable on `large-yolo-refactor`. |

---

*Report finalized 2026-06-11. Five P4b commits on `large-yolo-refactor`; suite 2964 / 0 / 449 / 0.*
