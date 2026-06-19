# P1 Results — Inventory Becomes the Live Concurrent::Map Store

> **Status:** COMPLETE. All 10 commits landed on `large-yolo-refactor`. Branch HEAD: `b7a67f6`.
> **Session:** P1 — Inventory Becomes the Live Concurrent::Map Store

---

## Performance Gate

> HUMAN MUST RUN: The baseline (`p0-baseline.md`) was never filled with actual numbers (daemon wasn't
> available to capture). The following is structural confirmation only.
>
> Per commit 8, `offerings()` now reads from the live `Concurrent::Map` store first (O(1) filtered
> read), falling back to `compose_offerings()` only when the store is empty (cold boot / test env
> without pre-populated store). Once `ScopedRefresher` actors have ticked (fills the live store),
> `offerings()` no longer calls `compose_offerings()` at all.
>
> The old per-call recompute cost (`build_offering × hundreds + dedupe + merge`) is eliminated for
> warmed-store requests. Expected improvement: offerings_calls collapses from ~4N to 1 (or 0
> once callers are migrated to `lanes_for` directly).

**HUMAN TODO**: Run the P0 baseline scenario and verify `offerings_calls ≤ 1` per request.

---

## Commit Map

| Commit | SHA | Status |
|--------|-----|--------|
| C1: Migrate routing_candidates → lanes_for | 6bb973b | ✅ Green |
| C2: Move discovery.rb → inventory/discovery.rb | 4e4f809 | ✅ Green |
| C3: Move capabilities.rb → inventory/capabilities.rb | f385b8a | ✅ Green |
| C4: Move discovery/{memory_gate,system}.rb → inventory/discovery/ | 02f936e | ✅ Green |
| C5: Introduce write_lane / delete_lane / lane / lanes / expired_ids | ea534f1 | ✅ Green |
| C6a: ScopedRefresher + Taxonomies + Capabilities in lex-llm | (lex-llm) | ✅ Green |
| C6b: Adopt ScopedRefresher in 9 lex-llm-* gems | (9 gems) | ✅ Green |
| C7: Inventory::Sweeper TTL safety net | fb1ddac | ✅ Green |
| C8: Switch offerings() to live map read | 5dc0270 | ✅ Green |
| C9: SettingsObserver + admin endpoint | 235ff9f | ✅ Green |
| C10: Exception log-level audit | 5b5d029 | ✅ Green |
| Exit: Fix spec regressions from Discovery move | b7a67f6 | ✅ Green |

**Final HEAD SHA: `b7a67f6`**

---

## Phase Exit Checklist

- [x] Commit 1: `routing_candidates` callers in `router.rb` migrated to `Inventory.lanes_for(**)`.
- [x] Commits 2–4: File moves landed verbatim. Compat shims verified. In-gem refs updated.
      `Legion::LLM::Discovery` compat still resolves for external callers via compat.rb
      (method_missing + method delegation to `Inventory::Discovery`).
- [x] Commit 5: `write_lane` / `delete_lane` / `lane` / `lanes` / `lanes_for` / `expired_ids`
      shipped. P0/B1 lane format specs green. `health: :preserve` sentinel (G21) implemented.
      5-part id validation (G22). `InvalidLane` error class added to errors.rb.
- [x] Commit 6a: `Taxonomies`, `Capabilities.normalize`, `ScopedRefresher.compose_id` shipped
      in lex-llm. P0/B4 spec green.
- [x] Commit 6b: All 9 lex-llm-* gems include ScopedRefresher. Per-gem `every_seconds` set.
      Each emits direct + fleet lanes per G29.
- [x] Commit 7: `Inventory::Sweeper` class ships. `Inventory.expired_ids` (not `.send(:map)`). P0/B5 spec green.
- [x] Commit 8: `offerings()` reads live store first (fallback to compose_offerings when empty).
      P0 instrumentation removed.
- [x] Commit 9: `SettingsObserver.attach!` wired on `Legion::LLM.start`. `handle_change` rewrites
      lanes preserving health. Admin endpoint `POST /api/llm/inventory/refresh` registered.
      **DEVIATION**: `Legion::Settings.observe(...)` API not available in current legion-settings.
      `attach!` is a no-op; manual endpoint is the reweight path for now.
- [x] Commit 10: Exception log-level audit complete. All `handle_exception(e, level: :debug)`
      bumped to `:warn` across legion-llm + lex-llm + 9 lex-llm-* gems.
- [x] `bundle exec rspec` 0 failures: 3276 examples, 27 pending (pre-existing RED specs for P2–P5).
- [x] `bundle exec rubocop` 0 offenses across legion-llm.

---

## Confirmations for P2

1. **`Inventory.write_lane(lane:, ttl: nil, health: :preserve, **)`** — implemented. `health: :preserve`
   semantics verified: refresher writes without `health:` kwarg preserve existing circuit state.
   Test: `spec/legion/llm/inventory/health_preserve_spec.rb` test 2 (explicit kwarg path) green.
   Test 1 (HealthTracker path) remains P2-pending because HealthTracker doesn't write to Inventory yet.

2. **All 9 lex-llm-* gems** have adopted `ScopedRefresher` with `compute_lanes_for_scope`,
   `scope_key`, `credential_hash`. Per-gem rspec and rubocop clean at commit time.

3. **`SettingsObserver.attach!`** wired at start. **DEVIATION**: settings observer API not available
   in legion-settings; `attach!` is a no-op stub. Admin endpoint `POST /api/llm/inventory/refresh`
   is the reweight mechanism. P2 can add proper observer if legion-settings adds the API.

4. **Audit complete**: zero `handle_exception(e, level: :debug)` across all 11 repos.

5. **HEAD SHA**: `b7a67f6` on `large-yolo-refactor`.

---

## Deviations from Phase Doc

1. **Commit numbering**: Phase doc says 8 commits; 10 were made (doc had C6a/C6b as one commit,
   plus the doc counted differently — C5=Sweeper in the doc but C7=Sweeper in execution).
   All phase doc work items were completed.

2. **P0 baseline not filled**: `p0-baseline.md` was never populated with daemon numbers.
   The performance gate (offerings_calls ≤ 1) is structural — confirmed by the live-store-first
   code path, not measured end-to-end. HUMAN must run the measurement.

3. **`Legion::Settings.observe`**: API doesn't exist in current legion-settings. `attach!` is a
   no-op stub. The G28 reweight lever (operator changes weight → immediate effect) works via the
   manual `POST /api/llm/inventory/refresh` endpoint.

4. **`health: :preserve` spec (G21) partially pending**: The spec that verifies HealthTracker
   trips → refresher preserves → spec green is deferred to P2 (requires HealthTracker→Inventory
   wiring). The `write_lane(health: explicit_kwarg)` path (test 2) is green.

5. **Discovery compat shim**: `rule_generator.rb` defines `Legion::LLM::Discovery` as a real
   Ruby constant (not via const_missing). `compat.rb` was extended with method_missing delegation,
   const aliases (System, MemoryGate, DISCOVERED_MODELS_SCHEMA_VERSION), and instance_variable
   forwarding to `Inventory::Discovery`. Specs updated to use `Inventory::Discovery` directly.

6. **`routing_candidates` spec deleted**: Spec block testing deleted method was removed from
   `inventory_spec.rb`. The method is gone in commit 8.

7. **`InvalidLane` at `Legion::LLM::InvalidLane`** (not `::Errors::InvalidLane`): The error
   classes in `errors.rb` are defined directly in `Legion::LLM`, not in an `Errors` module.
   inventory.rb and specs use `Legion::LLM::InvalidLane`.

8. **Lane weight defaults**: instance and model weights default to 100 (not inherited from
   provider weight). Spec `computes lane_weight from settings on write` confirmed: 100×200×100×100×1.0=200M.
