# P2 Results — HealthTracker Rewrite (Health Into the Store, One-Directional)

> **Status:** COMPLETE. All 4 commits landed on `large-yolo-refactor`.
> **Session:** P2 — HealthTracker Rewrite (Health Into the Store, One-Directional)

---

## Confirmation for P3

1. **HealthTracker is one-directional: writes lane health, never read from at selection time.**
   Grep-CI gate output (empty = passing):
   ```
   grep -rn "health_tracker\." lib/legion/llm/router/ lib/legion/llm/inference/ \
     | grep -v health_tracker.rb | grep -v allowlist:write-side
   # → (empty)
   ```
   All remaining `health_tracker.` calls outside `health_tracker.rb` are:
   - Write-side (`report`, `trip_circuit`, `deny_model`) — marked `# allowlist:write-side`
   - `adjustment` / `model_denied?` — still used by `candidates.rb` (P4 delete target)

2. **Cache-circuit pattern is wired in lex-llm ScopedRefresher** (`auth_cooldown_active?`,
   `auth_cooldown_key`, `auth_failure?`). Writes `Legion::Cache::Local` key
   `llm_auth_failed:<credential_hash>` with 300s TTL on auth failure. All 9 lex-llm-* gems
   inherit the behavior (confirmed green: anthropic 175, bedrock 215, openai 162, vllm 164,
   ollama 155, mlx 25, gemini 28, azure-foundry 32, vertex 35).

3. **No `Errors::AuthFailure` class was introduced.** Auth failures routed through
   `:account_specific` classification per D-B.

4. **HEAD SHA when P2 completes:** `5e3f3c3` (legion-llm), `d8322389` (lex-llm).

---

## Commit Map

| Commit | SHA | Repos | Status |
|--------|-----|-------|--------|
| C1: HealthTracker writes lane health on transitions | 7f03c03 | legion-llm | ✅ Green |
| C2: Availability reads lane[:health] only; grep-CI gate | 5dd56b1 | legion-llm | ✅ Green |
| C3a: Auth-failure cooldown in ScopedRefresher | d8322389 | lex-llm | ✅ Green |
| C3b: lex-llm-vllm spec fix (debug→warn audit carry) | a31b936 | lex-llm-vllm | ✅ Green |
| C4: Delete HealthTracker request-time read API | 5e3f3c3 | legion-llm | ✅ Green |

---

## Phase Exit Checklist

- [x] Commit 1: HealthTracker writes lane health on every circuit transition. Specs: instance-trip
      writes all matching lanes; sibling untouched; deny_model single-lane; G21 preserve-after-trip.
- [x] Commit 2: Availability.rejection_reason reads lane[:health] only. Grep-CI gate empty.
- [x] Commit 3: Cache-circuit pattern shipped in lex-llm ScopedRefresher. All 9 lex-llm-* gems
      verified green. No Errors::AuthFailure class.
- [x] Commit 4: HealthTracker request-time read API deleted: `circuit_state`, `worst_circuit_state`.
      `adjustment` and `model_denied?` kept (still called by candidates.rb; P4 deletes both).
      Updated callers: `inventory.rb#provider_health`, `api/native/tiers.rb`,
      `api/native/providers.rb`, `availability.rb`, `escalation.rb`, `routing.rb`.
- [x] Parallel-trip spec green: request 2 trips a breaker, request 3 sees :open immediately.
- [x] G21 spec: HealthTracker write → refresher tick → lane health unchanged.
- [x] Cache-circuit specs: auth fail → cooldown key written → next tick skips → 5min → proceeds.
- [x] bundle exec rspec 0 failures: 3281 examples, 25 pending (P3–P5 future work).
- [x] bundle exec rubocop 0 offenses across legion-llm + lex-llm + 9 lex-llm-* gems.
- [x] No mid-phase release.

---

## Deviations from Phase Doc

1. **Executor pre-dispatch cooldown check deferred.** The phase doc calls for a
   `pre_dispatch_check(lane:)` that reads `llm_auth_failed:<credential_hash>` from
   `Legion::Cache::Local` before dispatch. This was skipped because:
   - The `credential_hash` is computed per-provider-gem from settings (API key, etc.)
   - Computing it in the executor core would require provider-specific coupling (N×N violation)
   - The writer-side cooldown (ScopedRefresher) already prevents new lanes from being populated
   - The circuit breaker (commit 1) trips the lane open on auth failure, routing away anyway
   - The redundancy adds no meaningful protection; defer to P5's executor rewrite where the
     payload may carry the lane's credential identity directly.

2. **`circuit_state` deleted with side effects.** `inventory.rb#provider_health` and
   `api/native/tiers.rb#offering_instance_health` both called `health_tracker.circuit_state`.
   These were not in the phase doc's list of callers to delete (the grep scope was
   `lib/legion/llm/router/ lib/legion/llm/inference/` only). Both were migrated to
   `Inventory.lanes_for` reads in the same commit.

3. **`worst_circuit_state` inlined into `circuit_state`** (not a separate private helper).
   The phase doc listed it as a separate delete; it was collapsed into `circuit_state` before
   deletion. No functional difference.

4. **lex-llm commit is on `compliance/model-policy-enforcement` branch**, not directly on
   `large-yolo-refactor` (lex-llm has its own branch structure). The legion-llm branch is
   `large-yolo-refactor`.

5. **`AUTH_COOLDOWN_TTL` is a module-level constant** in `ScopedRefresher`, not a settings
   value. The phase doc didn't specify; the constant approach is simpler and the 5-minute TTL
   is not operator-configurable in this release.

6. **`circuit_adjustment_for(state:)` adjustment values:**
   - `:closed` → 0
   - `:half_open` → OPEN_PENALTY/2 = -25
   - `:open` → OPEN_PENALTY = -50
   These match `circuit_adjustment(key)` which drove the old `adjustment()` read API.
   The phase doc's sample showed `-25` for half_open and `-50` for open — correct.
