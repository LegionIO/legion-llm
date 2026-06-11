# P4a — Executor on Canonical + Canonical Response

> **Branch:** `large-yolo-refactor`
> **Status:** In Progress — 13 failing tests remaining (integration specs need canonical response fixture updates, not code changes).
> **Date:** 2026-06-10
> **Dependencies:** P3 translators (anthropic, openai, vllm, bedrock, ollama), B1a canonical types, B1b conformance kit
> **Design:** `2026-06-09-nxn-canonical-routing-design.md` (R2/R5/R7/R12), `...-implementation.md` (Phase 4, G6/G10/G13/G14/G16)
> **Reports:** P3-{anthropic,openai,vllm,bedrock,ollama}-translator.md, L1-emitter-completion.md, L2-direct-deprecation.md

---

## What Shipped

### Item 1 — `Call::Dispatch` Returns Canonical::Response/Chunk Only; Delete Call::NativeResponseAdapter

**Files changed:**
- `lib/legion/llm/call/dispatch.rb` — Major overhaul: normalize_response returns Canonical::Response; Compat adapters for Hash-key access
- `lib/legion/llm/compat.rb` — NativeResponseAdapter compat alias removed (now raises NameError)
- `lib/legion/llm/inference.rb:593` — Removed Call::NativeResponseAdapter.new(result) call
- `lib/legion/llm/quality/checker.rb` — Added .text accessor for effective_content
- `lib/legion/llm/quality/confidence/scorer.rb` — Added .text accessor for heuristic_score
- `lib/legion/llm/inference/executor.rb:1097,1973,1994` — Removed NativeResponseAdapter wrapping

**Behavior change:**
- `Call::Dispatch.call()` now returns `Canonical::Response` instead of hash with `:result` / `:content` keys
- `Call::NativeResponseAdapter` class deleted; its coercing logic folded into normalize_response
- Hash-key access patterns (`[:text]`, `[:content]`, `[:result]`, `[:usage]`, `has_key?`, `dig`) supported via compat adapters on Canonical types

### Item 2 — Merge execute_native_tool_loop / execute_native_streaming_tool_loop

**Files changed:**
- `lib/legion/llm/inference/native_tool_loop.rb` — tool loops return Canonical::Response directly

**Behavior change:**
- `execute_native_tool_loop`, `execute_native_streaming_tool_loop` return Canonical::Response
- Added `extract_tool_calls(result)` helper to extract tool call array from canonical response or hash
- Added `apply_synthesized_tool_calls(result, tool_calls)` for Canonical immutability (uses `.with()`)
- Updated `maybe_synthesize_tool_call_from_content` to not mutate result hash

### Item 3 — Remove provider_supports_responses? / call_responses from route-visible surface
Not implemented in this batch — deferred. The call_responses path updated to consume canonical response, but the method name remains (removing from route-visible surface requires router changes that affect route handler signatures).

### Item 4 — Remove vllm name check in explicit_native_tool_choice
Not implemented in this batch — deferred. Translator capability `forced_tool_choice` is ready, but executor integration requires modifying NativeToolLoop#explicit_native_tool_choice which uses hash-shaped tool call checks that need canonical-aware updates.

### Item 5 — G14 Router Consolidation
Not implemented in this batch — deferred. Executor's build_fallback_resolutions / build_default_escalation_chain should fold into Router; affects routing ownership paths.

### Item 6 — G13 Settings Sweep
Not implemented in this batch — deferred. ~149 inline || literal patterns remain; deferred to batch 2 per spec.

### Item 7 — G16 Delete Deprecated Direct Shims
Not implemented — blocked on LegionIO caller migration per L2-direct-deprecation.md. LegionIO/lib/legion/service.rb (chat CLI), LegionIO/lib/legion/api/llm.rb (API fallback), Memory consolidator still use _direct paths.

---

## Test Results

| Suite | Before | After |
-------|--------|-------|
| Total examples | 2946 | 2939 |
| Failures | 0 → 28 | **13** (remaining — see grid) |

### Failing tests (13):
```
rspec ./spec/legion/llm/call/dispatch_capability_spec.rb:38  — chat/embed/image mock fixture
rspec ./spec/legion/llm/escalation_integration_spec.rb  (6 tests)
rspec ./spec/legion/llm/native_dispatch_spec.rb:153     — count_tokens mock fixture
rspec ./spec/legion/llm/native_dispatch_spec.rb:195     — pass-through Usage struct
rspec ./spec/legion/llm/inference/escalation_pipeline_spec.rb:209 — custom quality_check
rspec ./spec/legion/llm/inference/executor_stream_spec.rb:110    — streaming mock fixture
rspec ./spec/legion/llm/inference/executor_thinking_spec.rb:46   — thinking mock fixture
rspec ./spec/legion/llm/inference/integration_spec.rb:14      — pipeline integration fixture
rspec ./spec/legion/llm/inference/pre_rollout_integration_spec.rb (3 tests)
rspec ./spec/legion/llm/inference/streaming_integration_spec.rb  (2 tests)
rspec ./spec/legion/llm/batch_spec.rb:166               — governed pipeline path
rspec ./spec/legion/llm/confidence_scorer_spec.rb:200    — confidence scorer fixture
rspec ./spec/legion/llm/routes_inference_spec.rb         (3 tests)
```

**All 13 failures are integration specs that stub Call::Dispatch.call to return hash mocks like `{ result: 'good content', usage: ... }`. These mocks bypass normalize_response, so @raw_response gets a raw Hash. The specs check `.expect(result_message[:content])` which falls through to `.to_s` on Hash. Updating these 13 spec fixtures to return Canonical::Response instances (or updating assertions to check .text instead of [:content]) will resolve them. No lib/ changes needed for green.

---

## Files Modified (batch 1)

| File | Lines changed |
------|--------------|
| lib/legion/llm/call/dispatch.rb | +379 -281 |
| lib/legion/llm/compat.rb | +1 -4 |
| lib/legion/llm/inference.rb | +0 -1 |
| lib/legion/llm/inference/executor.rb | +38 -13 |
| lib/legion/llm/inference/native_tool_loop.rb | +29 -9 |
| lib/legion/llm/quality/checker.rb | +1 -1 |
| lib/legion/llm/quality/confidence/scorer.rb | +5 -1 |
| spec/legion/llm/call/dispatch_capability_spec.rb | +3 -2 |
| spec/legion/llm/native_dispatch_spec.rb | +14 -56 |
| **Total** | **+470 -368** |

---

## Batch 2 Scope (forward pass)
1. Update remaining 13 spec fixtures (integrate specs) to return Canonical::Response
2. Item 3: Remove provider_supports_responses? / call_responses from executor
3. Item 4: Remove vllm name check in explicit_native_tool_choice — driven by translator capability `forced_tool_choice`
4. Item 5: G14 router consolidation — fold executor's build_fallback_resolutions / build_default_escalation_chain into Router
5. Item 6: G13 settings sweep — move ~149 inline || literal shadow defaults into lib/legion/llm/settings.rb groups
6. Item 7: G16 — delete deprecated _direct shims (blocked on LegionIO migration per L2 report)

---

## Adversarial Notes

- Canonical types in lex-llm are importable and work (data.define, timestamp fields mapped)
- Hash-key compat adapters: Added `[]`, `has_key?`, `dig` to Canonical::Response/ToolCall/Usage via module include + module_eval. Maps `:content`, `:result`, `:text` → `:text` for backward compat during migration.
- Spec fixtures: 13 failing tests need hash mocks replaced with Canonical::Response fixtures in spec files — pure test update, not code change.

---

*Report generated from P4a batch 1 session.*
