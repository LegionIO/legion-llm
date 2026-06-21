# legion-llm (v0.14.0)

Core LegionIO gem: LLM routing, provider dispatch, the inference pipeline, and the
OpenAI/Anthropic-compatible API surface. This file is loaded into **every** session — it is
intentionally short. Detailed reference lives in `README.md`; deep history lives in git.

## What it is (the one-paragraph model)

legion-llm is a **universal translation proxy**: N client dialects × N provider backends, any
direction. Every request parses **once** into a canonical form (`Canonical::Request`, owned by the
`lex-llm` gem), is routed/executed, then renders **once** back to the caller's dialect
(`Canonical::Response`). All provider wire-format translation lives in the `lex-llm-*` provider
gems. The daemon is an **execution proxy**, not a passthrough (see Invariants).

## Build & Test

```bash
bundle exec rspec      # ~3200 examples, must be 0 failures before any commit
bundle exec rubocop    # 0 offenses required (rubocop-legion plugin)
```

The **in-process matrix harness** (`spec/legion/llm/api/matrix/`) is the **commit gate**. It boots
the real Sinatra app, mounts `/v1/messages` `/v1/responses` `/v1/chat/completions`, and replays the
full client × scenario matrix against a deterministic `FakeProvider` in ~250ms. Any change to
`lib/legion/llm/api/`, the executor, or the canonical/translator boundary **must** pass it before
push. If a regression breaks live e2e but not the matrix, the matrix is missing a scenario — add it.

## Where things live (most-touched first)

| Area | Path |
|------|------|
| Facade (`start`, `chat`, `ask`, `embed`) | `lib/legion/llm.rb` |
| **Single source of truth for the catalog** | `lib/legion/llm/inventory.rb` |
| Router (`request_lane` — single selection) | `lib/legion/llm/router.rb`, `router/{availability,resolution,health_tracker}.rb` |
| Escalation history / failover | `lib/legion/llm/router/escalation/history.rb`, `inference/executor/escalation.rb` |
| Pipeline executor (18 steps, streaming) | `lib/legion/llm/inference/executor.rb` (+ `executor/*.rb`) |
| Pipeline steps | `lib/legion/llm/inference/steps/*.rb` |
| Client API routes | `lib/legion/llm/api/openai/`, `api/anthropic/`, `api/native/` |
| Canonical ↔ client translators | `lib/legion/llm/api/client_translators/*.rb` |
| Conversation curation | `lib/legion/llm/context/curator.rb` |
| Errors | `lib/legion/llm/errors.rb` |
| Settings/defaults | `lib/legion/llm/settings.rb` |
| Back-compat aliases | `lib/legion/llm/compat.rb` (const_missing, emits deprecation) |

Provider behaviour (default models, model filtering, capabilities) lives in the `lex-llm-*` gems at
`../extensions-ai/`, **not** here. `Legion::JSON.load` returns **symbol keys**.

## LLM Routing Invariants (non-negotiable; CI + cops enforce these)

These have caused production incidents. They are also enforced by `rubocop-legion`'s
`Legion/Framework` cops, lex-llm conformance fixtures, and the matrix harness.

1. **Execution-proxy contract.** To the *client*, the daemon is a server-side execution surface:
   LegionIO-resolved tools run server-side and appear in canonical server-tool shapes (Anthropic
   `server_tool_use`/`server_tool_result`; OpenAI Responses non-actionable output items with
   name+result) — the client never sees a pending call for a server-executed tool. To the
   *provider*, the daemon looks like the client: the same tool-use/tool-result exchange appears in
   the next turn in that provider's wire format. The model must know files changed.
2. **Always translate; never passthrough.** Every request → `Canonical::Request`; every response
   rendered from canonical. There is no "body is already in OpenAI shape, forward it" branch.
3. **No provider-name conditionals outside translators.** Routes, executor, tool loop, stream
   assembler, and router never branch on `provider == :x`. Provider-specific behaviour lives in that
   provider's translator, surfaced via `capabilities` flags.
4. **Thinking never crosses providers.** Reasoning/signatures/`redacted_thinking` survive
   same-provider replay; on any cross-provider transition (escalation, failover, tier swap) thinking
   is stripped. Signatures are provider-bound; foreign chain-of-thought is out-of-distribution.
5. **Mid-stream provider failover is first-class.** A provider outage must never kill an in-flight
   conversation. The `StreamAssembler` keeps one client SSE session while the canonical chunk source
   switches providers underneath.
6. **Every pipeline exit emits ledger events.** Success/sync, success/stream, error,
   escalation-exhausted, fleet-success/error, timeout, client-disconnect all route through the same
   emission path (metering + prompt-audit + tool-audit). No bypasses; `_direct` shims are deprecated.
   Fail closed when `llm.compliance.fail_closed` is set.
7. **The canary prompt.** "how many legionio tools do you have available?" → one response per
   prompt; server-executed tools run server-side; client-passthrough tools surface as pending
   calls for the client. Simplest end-to-end check that the proxy contract holds in both formats.

## Routing rules (RANKING v2 — current behaviour)

- **`Inventory` live `Concurrent::Map` is THE catalog.** Keyed by 5-part lane id
  `tier:provider:instance:type:model`. Written by `lex-llm-*` discovery actors via the
  `Inventory::ScopedRefresher` mixin. `HealthTracker` is the only other writer (owns `health`
  block per lane). Everyone reads the same map, lock-free.
- **`Router.request_lane(**routing_payload)` is the single selection method.** Returns one lane
  hash or `nil`. Hard filters → soft filter (lane_weight ≤ 0 excluded) → max-weight bucket →
  uniform sample. No pre-built chains.
- **Escalation = "ask again with the failed lane excluded."** Executor calls `request_lane` in a
  `while remaining.positive?` loop, appending tried lane ids to `tried_lanes`. No `loop do`.
- **`lane_weight = tier_w × provider_w × instance_w × model_w × health_mult`.** Precomputed on
  write. Negative = open circuit or policy-denied (excluded by soft filter). Surfaced in
  `/api/llm/providers/<p>/models`. Tunable via `settings[:llm][:routing][:weights]`.
- **`:fleet` is a first-class tier** in `Taxonomies::TIERS`. Fleet lanes written by `lex-llm-*`
  fleet workers appear alongside direct lanes.
- **`NoLaneAvailable` (400):** hard filters excluded everything before the first attempt.
  **`EscalationExhausted` (503 + `Retry-After`):** max attempts reached mid-flight.
- **Model policy is compliance.** `model_whitelist`/`model_blacklist` is honored at dispatch,
  fail-closed. A policy-denied model is **terminal** — never escalated, never trips circuits.
  Enforced at the daemon layer (`call/dispatch.rb` `enforce_model_policy!` →
  `Errors::ModelNotAllowed`) and in each `lex-llm-*` provider.

## Coding constraints (enforced in review + cops)

- **Never `::JSON`** — use `Legion::JSON.load`/`.dump`. `::Process`/`::JSON` must be explicit inside
  the `Legion::` namespace.
- **Never `defined?(Legion::Settings)` guards** — it's a hard dependency, always present.
- **Never swallow exceptions** — every `rescue` re-raises or calls
  `handle_exception(e, level:, operation:)`. No silent `rescue => e; nil`.
- **Every module/class gets `Legion::Logging::Helper`** — use `log.debug/info/warn/error`, never
  `puts`/`$stderr`. Debug logs must be diagnostic-complete: `[llm][component] action=verb key=value`.
- **No personal/company identifiers in VCS** — generic names (`primary`/`secondary`,
  `user@example.com`, `localhost`) in specs/changelog/commits. Never force-push.
- **Tunables in `lib/legion/llm/settings.rb`** — no inline `|| literal` shadow defaults.

## Debugging

When debugging legion-llm / lex-llm / lex-llm-* providers, read
`docs/work/planning/nxn-debugging-method.md` first. One catalog, one oracle: the matrix harness,
router specs, and e2e validators must assert the same routing facts.
