# P3 Results — Compliance by Absence (and the Catalog Collapse)

> **Status:** COMPLETE. All 4 commits landed on `large-yolo-refactor`.
> **Session:** P3 — Compliance by Absence (and the Catalog Collapse)

---

## Commit Map

| Commit | SHA | Status |
|--------|-----|--------|
| C1: Delete parallel offerings paths | ba610ba | ✅ Green |
| C2: Delete Discovery cache surface | 91d2f57 | ✅ Green |
| C3+C4: Policy specs + dispatch defense | 3eeb965 | ✅ Green |

**Final HEAD SHA: `3eeb965`**

---

## Audit Grep Output (Commit 1 + Commit 2)

### Commit 1 — Offerings paths audit

```bash
grep -rn "native_provider_offerings|discovery_offerings|dedupe_offerings|build_offering|add_fleet_lane|compose_offerings" lib/ spec/
```

**Before C1 (non-test callers in lib/):**
- `inventory.rb:119,139` — `compose_offerings` fallback in `offerings()`
- `inventory.rb:270-296` — `compose_offerings` definition
- `inventory.rb:282` — `native_provider_offerings` called from `compose_offerings`
- `inventory.rb:285-286` — `discovery_offerings`, `dedupe_offerings` called from `compose_offerings`
- `inventory.rb:364,380,384,399` — `build_offering` called from provider_offerings helpers
- `inventory.rb:459` — `add_fleet_lane` called from `build_offering`
- `inventory.rb:543-670` — all method definitions

**After C1 (non-test callers in lib/):** ZERO. All methods deleted.

```bash
grep -rn "Legion::LLM::Inventory\.(native_provider_offerings|discovery_offerings|dedupe_offerings|build_offering|add_fleet_lane)" /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/
```

**Result:** ZERO external callers. `build_offering` in lex-llm-* gems is a LOCAL method on those gems' own classes — unrelated to `Inventory#build_offering`.

### Commit 2 — Discovery cache surface audit

```bash
grep -rn "cached_discovered_models|discovered_models|discovered_instances|refresh_discovered_models" lib/ spec/
```

**Before C2 (non-test callers in lib/):**
- `lib/legion/llm.rb:90` — `Discovery.discovered_instances` (startup call)
- `lib/legion/llm/inventory.rb:577-580` — `Discovery.cached_discovered_models` inside `discovery_offerings` (deleted with C1)
- `lib/legion/llm/router.rb:70-73` — `discover_provider_for_model` (guarded `respond_to?` check)
- `lib/legion/llm/router/availability.rb:175` — `instance_resolution_required?`
- `lib/legion/llm/inference/executor/routing.rb:326` — `resolve_model_to_local_provider`

**After C2 (non-test callers in lib/):** ZERO.

```bash
grep -rn "cached_discovered_models|discovered_models|discovered_instances|refresh_discovered_models" /Users/matt.iverson@optum.com/rubymine/legion/extensions-ai/
```

**Before C2:** 8 lex-llm-* gems had `discovery_refresh.rb` actors calling `Legion::LLM::Discovery.refresh_discovered_models!` and `discovered_instances` — State A (dual-call; P1 C6b added ScopedRefresher alongside legacy calls).

**After C2:** All 9 `discovery_refresh.rb` actors — legacy tail removed. ZERO external callers.

---

## Deviations from Phase Doc

1. **P3 ships as 3 commits, not 4.** C3 and C4 were combined into a single commit since they're both spec-only changes with no production code edits. The phase doc listed them separately; combined commit covers both.

2. **Commit 2 scope expanded** (per stop-condition analysis): Phase doc scoped C2 to `inventory/discovery.rb` only. After audit, 3 live callers of `cached_discovered_models` were found in router/executor:
   - `router.rb:70-73` `discover_provider_for_model` — deleted (guarded; body now dead)
   - `availability.rb:175` `instance_resolution_required?` — migrated to `Inventory.lanes_for`
   - `executor/routing.rb:326` `resolve_model_to_local_provider` — migrated to `Inventory.lanes_for` (local/direct/fleet tiers)
   
   All three migrated in the same C2 commit per the standing rule: internal-only deletes happen in the same release.

3. **`validate_lane!` bugfix in C1**: `split(':')` was changed to `split(':', 5)` to allow model names containing colons (e.g. `amazon.titan-embed-text-v2:0`). This was a pre-existing bug in the P1 validator, discovered during spec migration.

4. **`offerings()` filter bugfix in C1**: Fixed a nil-matching false-positive — when `model:` was set but `offering_id:` was nil, the old filter checked `nil.to_s == nil.to_s` which always passed. Separated the two filter branches.

5. **`model_size` now returns nil**: Post-P3, `size_bytes` is not stored on Inventory lanes. `Discovery.model_size` is preserved as a no-op returning nil for interface compatibility; downstream callers (embedding scoring) treat nil as unknown.

6. **`discover_provider_for_model` deleted (not just guarded)**: The method was guarded by `Discovery.respond_to?(:cached_discovered_models)` — after deleting `cached_discovered_models`, the guard would always be false. Deleted the whole method instead of leaving dead code. `infer_provider_for_model` now uses regex-only inference; colon-pattern names like `qwen3.6:27b` now infer `:ollama` (correct behavior for the Ollama tag format).

7. **`/api/llm/offerings` HUMAN curl**: Not run — daemon not available in this session. The API surface test in C3 (`compliance_spec.rb`) provides spec-level compliance proof through the real Sinatra app + `Rack::MockRequest`. HUMAN should verify with a live curl after deploying with denied-model settings, per the phase doc's gate.

8. **`enforce_model_policy!` test uses mock `model_allowed?`**: The dispatch defense-in-depth test uses a mock extension module with a hardcoded `model_allowed?` method rather than wiring through `Inventory`'s blacklist. This is correct — `enforce_model_policy!` delegates to the provider extension's own `model_allowed?` (from `Legion::Extensions::Llm::Provider`). In production, the provider gem reads its settings blacklist/whitelist. The test verifies the dispatch layer raises `ModelNotAllowed` when the extension denies the model.

---

## Phase Exit Checklist

- [x] Commit 1: `native_provider_offerings`, `discovery_offerings`, `dedupe_offerings`,
      `build_offering`, `add_fleet_lane`, `compose_offerings` deleted. Specs migrated.
- [x] Commit 2: `cached_discovered_models` / `discovered_models` / `discovered_instances` /
      `refresh_discovered_models!` deleted. 9 lex-llm-* actors cleaned. 3 live callers migrated.
      Const alias for `DISCOVERED_MODELS_SCHEMA_VERSION` removed from compat.rb.
- [x] Commit 3: Comprehensive whitelist/blacklist specs in `compliance_spec.rb`:
      blacklist, whitelist, precedence (whitelist > blacklist), cross-provider isolation,
      API surface absence (Rack::MockRequest level), runtime IAM-deny, settings reload.
- [x] Commit 4: `dispatch_capability_spec.rb` defense-in-depth spec — `ModelNotAllowed` raised
      when caller passes blacklisted model directly to `Call::Dispatch.call`.
- [x] Audit grep output documented above.
- [x] `/api/llm/offerings` compliance verified at spec level (Rack::MockRequest).
      HUMAN live-curl deferred (daemon not available).
- [x] `bundle exec rspec` 0 failures: 3281 examples, 25 pending (P4–P5 future RED specs).
- [x] `bundle exec rubocop` 0 offenses.
- [x] No mid-phase release.
- [x] All commits on `large-yolo-refactor`.

---

## Confirmations for P4

1. **Catalog collapse is total.** `native_provider_offerings`, `discovery_offerings`,
   `dedupe_offerings`, `build_offering`, `add_fleet_lane`, `compose_offerings`, and the entire
   `Legion::LLM::Discovery.cached_discovered_models` cache surface are deleted with zero callers.
   Audit grep output confirms.

2. **Whitelist precedence is correct.** Whitelist > blacklist. Whitelist mode rejects non-whitelisted
   regardless of blacklist content. Specs confirm all corner cases.

3. **`Call::Dispatch.enforce_model_policy!` defense-in-depth spec passes.** Library callers cannot
   bypass policy by dispatching directly with a hardcoded denied model name.

4. **`/api/llm/offerings` shows denied models absent.** Verified via `Rack::MockRequest` in
   `compliance_spec.rb` — blacklisted model not in response; allowed model present.

5. **HEAD SHA when P3 completes:** `3eeb965` on `large-yolo-refactor`.
