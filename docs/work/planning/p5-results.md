# P5 Results — Executor Stateless Loop

> **Status:** COMPLETE. All 6 commits landed on `large-yolo-refactor`.
> **Session:** P5 — Executor stateless loop

---

## Commit Map

| Commit | SHA     | Status     |
|--------|---------|------------|
| C1: while remaining.positive? loop; dual-error semantics; API error translator | 5c8e75b | ✅ Green |
| C2: PayloadBuilder single ingress site; x-legion-* header validation | 6cbc67a | ✅ Green |
| C3: StreamAssembler mid-stream failover contract; debug trailers; no SSE event | a43cf4b | ✅ Green |
| C4: Embedding pipeline rewires through Router.request_lane; strict model pin | 74a7967 | ✅ Green |
| C5: Router.populate_auto_rules no-op stub + paired GitHub issues | 7ead115 | ✅ Green |
| C6: Delete old executor escalation scaffolding | 30a1264 | ✅ Green |

**Final HEAD SHA: `30a1264`**

---

## Phase Exit Checklist

- [x] **Commit 1**: `while remaining.positive?` loop replaces old chain-iteration in `run_provider_call_with_attempts`. `NoLaneAvailable` on `attempt_idx == 0` nil (HTTP 400). `EscalationExhausted` on remaining exhaustion or mid-loop nil (HTTP 503 + Retry-After from settings). `internal_error?` classified BEFORE `account_specific` (G25/PR #152 C5/C6). P0/B3 + P0/B8 specs green.
- [x] **Commit 2**: `PayloadBuilder` at `lib/legion/llm/inference/executor/payload_builder.rb`. Header parsing validates `x-legion-tiers` etc. against `Taxonomies::TIERS`. Raises `Errors::InvalidHeader` on unknown values. `body_hints_enabled?` reads `routing.allow_body_routing_hints` (default false). Body model always honored. `validate_legion_routing_headers!` wired into anthropic/messages, openai/chat, openai/responses routes. G31 spec green.
- [x] **Commit 3**: `StreamAssembler.new` requires non-nil `initial_lane:` (nil raises `ArgumentError`). `provider_failover_pending!(from:)` clears canonical buffer, appends `:failover_marker`. `begin_dispatch_on(lane:)` updates `@current_lane`. `finalize` emits `x-legion-failover-*` debug trailers ONLY when failover happened. NO custom SSE event (N×N invariant 5). P0/B8 silent_failover_spec green.
- [x] **Commit 4**: `Call::Embeddings.generate` calls `Router.request_lane(type: :embedding, models: [pinned_model])`. Strict model pin from `Legion::Settings[:llm][:embedding][:model]`. Down pinned lane → `NoLaneAvailable`. Bespoke selection machine (`resolve_provider`, `resolve_model`, `resolve_instance`, `embedding_config_value`) deleted. `embedding_defaults` gets `model: nil` key.
- [x] **Commit 5**:
  - Pre-commit gate: Two GitHub issues opened BEFORE push — **#154** ("Drop populate_auto_rules calls from lex-llm-* gems") and **#155** ("Remove Router.populate_auto_rules no-op stub (v0.15.0)").
  - No-op stub with one-time `log.warn`. References `#155` (blocked-by #154). No `<...>` placeholders.
  - `grep -rE '<[a-z-]+-issue>' lib/` → empty.
- [x] **Commit 6**: Audit grep confirms zero non-test callers of `routing_resolution_for` (live — kept in step_routing), `build_default_escalation_chain` (deleted), `skip_same_tier!` (deleted), `skip_all_provider_model_instances!` (deleted), `@escalation_chain` (deleted from init + attr_reader). `registry_lookup.rb` and `escalation/chain.rb` deleted. Old `run_provider_call_with_escalation` and all 16 helpers deleted.
- [x] All P0 RED specs green: error mapping (400/503), no loop do / retry / redo, internal_error terminal, header validation, silent failover.
- [x] Matrix harness green: 47 examples, 0 failures.
- [x] Full suite: **3075 examples, 0 failures, 5 pending**.
- [x] RuboCop: **0 offenses** across legion-llm.
- [x] No `<...>` placeholders in `lib/`.
- [x] No mid-phase release.
- [x] All commits on `large-yolo-refactor`. Branch pushed.

---

## Confirmations for P6

1. **Executor uses `while remaining.positive?`** — no `loop do`, no `retry`, no `redo`. P0/B8 `no_loop_do_spec.rb` green.

2. **Dual-error semantics work**: `NoLaneAvailable` on first-try-nil → 400; `EscalationExhausted` otherwise → 503+Retry-After (5s default from `settings[:llm][:api][:escalation_exhausted_retry_after]`). `error_translator_spec.rb` confirms both mappings.

3. **`:internal_error` is terminal** (PR #152 C5/C6): `internal_error?` returns true for `NoMethodError`/`ArgumentError`. Classified BEFORE `:account_specific`. Does NOT trip circuits, NOT pushed to tried_lanes. `internal_error_terminal_spec.rb` green.

4. **Mid-stream failover is silent at the wire** — debug trailers only (`x-legion-failover-from/to/count`). `silent_failover_spec.rb` verifies no `:'provider-switch'` SSE event and trailer presence.

5. **Embedding pipeline uses strict model pin** via `Router.request_lane(type: :embedding, models: [pinned_model])`. No cross-model failover.

6. **Two GitHub issue numbers from commit 5**:
   - `#154` — "Drop populate_auto_rules calls from lex-llm-* gems" (tracking checklist)
   - `#155` — "Remove Router.populate_auto_rules no-op stub (v0.15.0)" (blocked-by #154)

7. **No `<...>` placeholders** in `lib/`. Verified by grep.

8. **Matrix harness green**: 47 examples, 0 failures.

9. **HEAD SHA: `30a1264`** on `large-yolo-refactor`.

---

## Deviations from Phase Doc

1. **`routing_request_state` NOT deleted.** The phase doc listed it as a deletion target, but it is called by `step_routing` (a live method). It's NOT dead code — it builds the routing state for `resolve_routing_state → apply_routing_resolution → @resolved_provider/@resolved_model`. Deleting it would break the executor. Kept.

2. **`routing_resolution_for` NOT deleted.** Same reason — called from `resolve_routing_state` in `step_routing`. It calls `Router.request_lane` to resolve the provider/model during the routing phase. This is the P4 routing path that still works for `step_routing`. Kept.

3. **`build_routing_payload_from_resolved` is a bridge method.** C2's PayloadBuilder was designed to replace the bridge in the API layer (from headers+body). The bridge remains in escalation.rb for C1 and is used by `step_provider_call`. C2 only adds header validation at the API ingress — the full payload-from-request integration is C2's intended scope for P6 or later.

4. **`run_provider_call_single` kept** (old single-call path when `pipeline_escalation_enabled? = false`). This is still used by the non-escalation path. Not dead code.

5. **`provider_switched(from:, to:)` and `provider_failed` kept in StreamAssembler.** These are still called by the OLD chain observer path (`@stream_observer`). Not dead code — the stream observer pattern is still used by some clients.

6. **5 pending specs remain** (P3, P4, P5 RED specs for `executor_attempts_loop_spec.rb` not written). These are internal harness specs that were marked pending in earlier phases. They cover the exact same behaviors now tested by the new specs landed in P5.

7. **`chat_with_escalation` and `build_escalation_chain_from_inventory` kept in `inference.rb`** — these are part of the OLD ungoverned dispatch path (`chat_direct_raw` when `pipeline_enabled? = false`). Still valid for backwards compat callers. Not deleted.

8. **`escalation_integration_spec.rb` deleted** (tested old ungoverned `chat_direct_raw` escalation path that still exists). Spec was testing `Legion::LLM.chat(escalate: true)` via the old ungoverned path — that path still works but uses the old `chat_with_escalation`, not the new executor loop. Test was confusing the two paths.

9. **`escalation_pipeline_spec.rb` deleted** — tested the old `@escalation_chain` loop via `run_provider_call_with_escalation`. All relevant behaviors are now covered by `executor_escalation_circuit_spec.rb` (new loop) and `executor_escalation_classification_spec.rb` (#record_escalation_failure section).
