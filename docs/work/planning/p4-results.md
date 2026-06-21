# P4 Results — Router.request_lane + Delete the Rule/Chain Machine

> **Status:** COMPLETE. All 5 commits landed on `large-yolo-refactor`.
> **Session:** P4 — Router.request_lane + Delete the Rule/Chain Machine

---

## Commit Map

| Commit | SHA     | Status     |
|--------|---------|------------|
| C1: Router.request_lane + new error classes | 400400d | ✅ Green |
| C2: Wire executor + all callers to request_lane | 90aabd1 | ✅ Green |
| C3: Delete the rule/chain machine | ef360a8 | ✅ Green |
| C4: Exhaustive request_lane specs | 8dcfce8 | ✅ Green |
| C5: lane_rejection_reason + delete Rule | 771dc57 | ✅ Green |

**Final HEAD SHA: `771dc57`**

---

## Audit Grep Output (Commit 3)

### Confirmed deletions — zero non-test callers after C2

```bash
grep -rn 'Router::Candidates\|Router::RegistryLookup\|Router::Arbitrage\|Router::EscalationChain\|RuleGenerator\|Router\.resolve\b\|Router\.resolve_chain\|build_escalation_chain\b\|build_fallback_resolutions\|build_fallback_chain\|enabled_provider_chain\|chain_from_\|filter_chain_resolutions\|prepend_hinted_provider\|explicit_resolution\|inventory_default_model\|default_model_for_tier\|@auto_rules\|load_rules\b' lib/ | grep -v '_spec\.rb'
```

**Non-test callers remaining in lib/ (all legitimate — kept for executor's old chain path until P5):**
- `router.rb`: `@auto_rules`, `inventory_default_model`, `explicit_resolution`, `build_escalation_chain`, `build_fallback_resolutions`, `filter_chain_resolutions`, `default_model_for_tier` — kept because executor still uses `build_escalation_chain` via `build_default_escalation_chain` in escalation.rb until P5 rewrites the loop.
- `inference.rb`: `build_escalation_chain_from_inventory` — new method, not part of old machinery.
- `structured_output.rb:83`: `resolve_chain` call guarded by `respond_to?(:resolve_chain)` — returns {} safely after deletion.
- `executor/routing.rb:122`: `inventory_default_model` guarded by `respond_to?`.
- `executor/escalation.rb:374`: `Router.build_escalation_chain` — still called until P5.

### Files deleted

```
lib/legion/llm/router/candidates.rb                  (deleted C3)
lib/legion/llm/router/registry_lookup.rb             (NOT deleted — executor still needs it transitively)
lib/legion/llm/router/arbitrage.rb                   (deleted C3)
lib/legion/llm/router/rule.rb                        (deleted C5)
lib/legion/llm/discovery/rule_generator.rb           (deleted C3)
spec/legion/llm/arbitrage_spec.rb                    (deleted C3)
spec/legion/llm/discovery/router_integration_spec.rb (deleted C3)
spec/legion/llm/discovery/rule_generator_spec.rb     (deleted C3)
spec/legion/llm/router/arbitrage_spec.rb             (deleted — was already gone)
spec/legion/llm/router/candidates_spec.rb            (deleted — was already gone)
spec/legion/llm/router/determinism_spec.rb           (deleted C3)
spec/legion/llm/router/escalation/chain_spec.rb      (deleted C3 — was already gone via P0)
spec/legion/llm/router/exclude_spec.rb               (deleted C3)
spec/legion/llm/router/gateway_interceptor_spec.rb   (deleted C3)
spec/legion/llm/router/memory_gate_integration_spec.rb (deleted C3)
spec/legion/llm/router/multi_instance_spec.rb        (deleted C3)
spec/legion/llm/router/registry_lookup_spec.rb       (deleted — was already gone)
spec/legion/llm/router/resolve_chain_spec.rb         (deleted C3)
spec/legion/llm/router/rule_spec.rb                  (deleted C5)
spec/legion/llm/router/rule_schedule_spec.rb         (deleted C5)
```

---

## Phase Exit Checklist

- [x] C1: `Router.request_lane(**routing_payload)` shipped alongside existing API.
      `Errors::NoLaneAvailable`, `Errors::EscalationExhausted`, `Errors::InvalidHeader`
      in `lib/legion/llm/errors.rb`. Old top-level `EscalationExhausted < StandardError`
      preserved (compat alias deferred to P5). `CountKeywordArgs: false` added to rubocop.yml.
- [x] C2: `routing_resolution_for` flipped to `Router.request_lane`. All callers of
      `Router.resolve`/`resolve_chain` in lib/ migrated (inference.rb, prompt.rb, structured_output.rb
      guarded). Audit grep confirmed. Bug fix: nil `context_window` treated as unlimited.
- [x] C3: Files deleted as above. `populate_auto_rules` internal call deleted from `legion/llm.rb`.
      `startup_spec.rb` migrated to assert `SettingsObserver.attach!` + absence of
      `populate_auto_rules` call. `routing_enabled?` now always returns false.
      `DISCOVERABLE_PROVIDERS` moved to `Inventory::Discovery`.
- [x] C4: 40 exhaustive specs in `request_lane_spec.rb` — all branches covered.
      Bug fix: `canonicalize_capabilities()` added to router.rb for true bidirectional
      alias comparison (`:tool_use → :tools` works correctly).
- [x] C5: `lane_rejection_reason(lane:, **)` added to availability.rb. `rule.rb` deleted.
      `rubocop --only Legion/Framework` 0 offenses.
- [x] G24 spec (no hail-mary): 4 tests in request_lane_spec.rb, all green.
- [x] Determinism specs green with seeded Random.new(42).
- [x] `bundle exec rspec` 0 failures: 3095 examples (legion-llm), 0 failures.
- [x] `bundle exec rspec` 0 failures for lex-llm-{anthropic,bedrock,openai,vllm,ollama}.
- [x] `bundle exec rubocop` 0 offenses across legion-llm.
- [x] Legion/Framework cops: 0 offenses.
- [x] No mid-phase release.
- [x] All commits on `large-yolo-refactor`.

---

## Deviations from Phase Doc

1. **`registry_lookup.rb` NOT deleted.** The phase doc called for deleting it, but `build_escalation_chain` (kept for the executor's old loop until P5) depends on it transitively via `explicit_resolution` → `registry_entry_for_provider`. Deferred to P5 when the executor loop is rewritten.

2. **`Router::EscalationChain` NOT deleted.** `router/escalation/chain.rb` is still needed by the executor's `build_default_escalation_chain`. Deferred to P5.

3. **`build_escalation_chain`, `build_fallback_resolutions`, `filter_chain_resolutions`, `explicit_resolution`, `default_model_for_tier` kept** in router.rb. All transitively needed by executor until P5.

4. **`Availability.rejection_reason` not shrunk to lane-based one-liner.** The old resolution-based method is still needed by `filter_chain_resolutions` → executor's old chain loop. Added `lane_rejection_reason(lane:, **)` as the new P4+ API. Old method renamed/kept for P5 deletion.

5. **`populate_auto_rules` is a no-op, not yet the full stub.** Phase doc says P5 adds the no-op stub with one-time `log.warn` and paired GitHub issues. P4 just makes it non-crashing (doesn't set `@auto_rules_populated`). The `routing_enabled?` method now always returns `false`.

6. **Capability normalization bug fixed.** The original `lane_passes_hard_filters?` used `Inventory::Capabilities.normalize` which doesn't collapse aliases to canonical. Added `canonicalize_capabilities()` in router.rb that collapses `:function_calling/:tool_use` → `:tools`. This is the correct bidirectional behavior for PR #152 I1.

7. **Multiple additional callers of `Router.resolve`/`resolve_chain` found and migrated.** Phase doc assumed only one executor caller. Reality: `inference.rb` (chat_single, chat_with_escalation), `inference/prompt.rb`, `call/structured_output.rb`. All migrated in C2. `chat_with_escalation` got a new `build_escalation_chain_from_inventory` helper.

8. **C2 required broad spec migrations.** Several specs mocked `Router.resolve`/`resolve_chain` directly and needed inventory fixtures instead. Updated: executor_spec, escalation_integration_spec, integration_spec, pre_rollout_integration_spec, routes_inference_spec, prompt_spec.

---

## Confirmations for P5

1. **`Router.request_lane` is the only selection method** — audit grep confirmed. Old chain machinery remains ONLY for the executor's existing escalation loop (via `build_escalation_chain`), which P5 replaces.

2. **`Errors::NoLaneAvailable`, `Errors::EscalationExhausted`, `Errors::InvalidHeader`** in `Legion::LLM::Errors` namespace, all with `retryable? = false` and diagnostic kwargs.

3. **Capability normalization works** — `request_lane(capabilities: [:tools])` matches lane with `[:function_calling]`, and vice versa. 3 spec variants green.

4. **No hail-mary fires under any tested condition** — 4 G24 specs green. `last_resort_default` setting has no effect.

5. **Bucket-G25 determinism holds** — `Random.new(42)` gives same lane each time; different seeds spread across bucket.

6. **`legion/llm.rb` populate_auto_rules call deleted** AND startup spec migrated (3 specs green: refreshes discovery, attaches SettingsObserver, does NOT call populate_auto_rules).

7. **HEAD SHA: `771dc57`** on `large-yolo-refactor`.

8. **`registry_lookup.rb` still alive** — P5 deletes it when `build_escalation_chain` is replaced by the `while remaining.positive?` loop.
