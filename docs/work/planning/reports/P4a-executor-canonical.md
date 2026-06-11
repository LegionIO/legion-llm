# P4a — Executor on Canonical + Canonical Response

> **Branch:** `large-yolo-refactor`
> **Status:** DONE (items 1-6 green); Item 7 BLOCKED on caller migration
> **Date:** 2026-06-11
> **Dependencies:** P3 translators (anthropic, openai, vllm, bedrock, ollama), B1a canonical types, B1b conformance kit
> **Design:** `2026-06-09-nxn-canonical-routing-design.md` (R2/R5/R7/R12), `...-implementation.md` (Phase 4, G6/G10/G13/G14/G16)
> **Reports:** P3-{anthropic,openai,vllm,bedrock,ollama}-translator.md, L1-emitter-completion.md, L2-direct-deprecation.md

---

## Suite Status

```
2939 examples, 0 failures
441 files inspected, no offenses detected
```

---

## Items

### Item 1 — `Call::Dispatch` Returns Canonical::Response/Chunk Only; Delete Call::NativeResponseAdapter — DONE

**Commit:** `21ea320`

**Files changed:**
- `lib/legion/llm/call/dispatch.rb` — normalize_response returns Canonical::Response; compat adapters for Hash-key access
- `lib/legion/llm/compat.rb` — NativeResponseAdapter compat alias removed
- `lib/legion/llm/inference.rb` — Removed Call::NativeResponseAdapter.new(result) call
- `lib/legion/llm/quality/checker.rb` — .text accessor for effective_content
- `lib/legion/llm/quality/confidence/scorer.rb` — .text accessor for heuristic_score
- `lib/legion/llm/inference/executor.rb` — Removed NativeResponseAdapter wrapping

**Behavior:** `Call::Dispatch.call()` returns `Canonical::Response`. NativeResponseAdapter deleted.

### Item 2 — Merge execute_native_tool_loop / execute_native_streaming_tool_loop — DONE

**Commit:** `21ea320`

**Files changed:**
- `lib/legion/llm/inference/native_tool_loop.rb` — tool loops return Canonical::Response directly

**Behavior:** Both tool loops return Canonical::Response. `extract_tool_calls`/`apply_synthesized_tool_calls` handle canonical immutability via `.with()`.

### Item 3 — Remove provider_supports_responses? / call_responses from route-visible surface — DONE

**Commit:** `74dcff9`

**Files changed:**
- `lib/legion/llm/inference/executor.rb` — `call_responses` now internally falls back to `call`/`call_stream`; no external check needed
- `lib/legion/llm/api/namespaces/openai/responses.rb` — simplified to `executor.respond_to?(:call_responses)`
- `lib/legion/llm/api/openai/responses.rb` — `call_streaming_executor` simplified

**Behavior:** `provider_supports_responses?` is no longer consulted by callers. `call_responses` handles fallback internally.

### Item 4 — Remove vllm name check in NativeToolLoop#explicit_native_tool_choice — DONE

**Commit:** `027eb29`

**Files changed:**
- `lib/legion/llm/inference/native_tool_loop.rb` — Replaced `@resolved_provider.to_s == 'vllm'` with `ext.translator.capabilities[:forced_tool_choice]`

**Behavior:** Tool choice activation is capability-driven via translator, not provider-name-driven.

### Item 5 — G14 Router Consolidation — DONE

**Commit:** `f505875`

**Files changed:**
- `lib/legion/llm/router.rb` — Added `build_escalation_chain` and `build_fallback_resolutions` as public Router methods
- `lib/legion/llm/inference/executor.rb` — `build_default_escalation_chain` delegates to `Router.build_escalation_chain`

**Behavior:** Router owns all escalation chain construction. Executor no longer duplicates fallback resolution logic.

### Item 6 — G13 Settings Sweep — DONE

**Commit:** `fbb8d65`

**Files changed (21 files):**
- `lib/legion/llm/settings.rb` — Added `providers: {}`, `tier_order: nil`, `pricing: {}`, `batch_pool_size: 4`
- Removed ~30 redundant `|| fallback` patterns across: router.rb, cache/response.rb, cache.rb, call/embeddings.rb, call/structured_output.rb, context/curator.rb, discovery/system.rb, fleet/dispatcher.rb, fleet/token_issuer.rb, inference.rb, inference/executor.rb, inference/steps/knowledge_capture.rb, metering.rb, metering/tracker.rb, scheduling.rb, scheduling/batch.rb, api/native/models.rb, api/native/tiers.rb, api/namespaces/openai/batches.rb
- Retained `dig` with fallback for deeply-nested paths accessed via test stubs (auth, fleet dispatch, health tracker)
- `spec/legion/llm_spec.rb` — Updated providers assertion

**Behavior:** Code relies on settings.rb defaults instead of inline literals. Single source of truth for all default values.

### Item 7 — G16 Delete Deprecated `_direct` Shims — BLOCKED

**Blocked on:** LegionIO callers still use `chat_direct`:
- `LegionIO/lib/legion/memory/consolidator.rb:164,189`
- `LegionIO/lib/legion/cli/chat_command.rb:246,262`
- `LegionIO/lib/legion/cli/chat/tools/reflect.rb:63,127`
- `LegionIO/lib/legion/cli/chat/tools/consolidate_memory.rb:69,73`

`embed_direct` and `structured_direct` have no external callers — could be deleted independently if desired.

---

## P6 Deletion List (DEPRECATED adapters from batch 1)

These DEPRECATED(P6) Hash-key compat adapters MUST be deleted in Phase 6:

| Location | Adapter | Purpose |
|----------|---------|---------|
| `lib/legion/llm/call/dispatch.rb` | `CanonicalResponseCompat` module | `[]`, `has_key?`, `dig` on Canonical::Response |
| `lib/legion/llm/call/dispatch.rb` | `CanonicalToolCallCompat` module | `[]`, `has_key?`, `dig` on Canonical::ToolCall |
| `lib/legion/llm/call/dispatch.rb` | `CanonicalUsageCompat` module | `[]`, `has_key?`, `dig` on Canonical::Usage |
| `lib/legion/llm/call/dispatch.rb` | `Canonical::Response.class_eval` | `:result`/`:content` key fallback to `.text` |

Each adapter logs `[llm][DEPRECATED(P6)] canonical_hash_access key=... caller=...` on every access. Grep for `DEPRECATED(P6)` to find survivors before deletion.

---

## Commits (chronological)

| Hash | Message |
|------|---------|
| `84b7d5a` | docs: P4a executor canonical report (batch 1) |
| `21ea320` | feat(get-1-5): canonical crate response (P4a batch 1) |
| `ecbf243` | fix: P4a batch 1 spec fixtures + DEPRECATED(P6) compat adapters |
| `027eb29` | feat(P4a-4): replace vllm name check with translator capability query |
| `74dcff9` | feat(P4a-3): internalize provider_supports_responses? into executor |
| `f505875` | feat(P4a-5): consolidate escalation chain building into Router (G14) |
| `fbb8d65` | feat(P4a-6): settings sweep — consolidate inline || defaults into settings.rb (G13) |

---

*Report finalized 2026-06-11. All items green except Item 7 (blocked on LegionIO caller migration).*
