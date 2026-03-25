# LLM Pipeline Gap Analysis

**Date**: 2026-03-23
**Scope**: All 5 implementation plans vs routing-reenvisioned.md, llm-schema-spec.md, TODO.md, design-backlog.md, GAS docs, mind_growth_TODO, async-updates-TODO, teams-rag-bridge idea
**Author**: Gap analysis session

---

## Critical Gaps (Blocks the Vision)

### 1. ConversationStore -- No Plan Builds It

The routing-reenvisioned doc's core concept is `ConversationStore` -- per-message persistence, UUID-keyed, the "spine" of the whole system. Steps 5 (Context Load) and 15 (Context Store) depend on it.

**None of the five plans build it.** Plan 1 builds Request/Response structs and the pipeline skeleton. Plan 2 builds GAIA advisory. Plan 3 builds RAG via Apollo. Plan 4 builds MCP client. Plan 5 builds Catalog.

The conversation UUID is generated (Plan 1, Task 1 creates the Request struct with `conversation_id`), but there's no `ConversationStore` class, no message table, no persistence. The pipeline creates conversation IDs that go nowhere.

**Impact**: The whole portable-conversation vision (start in interlink, continue in CLI, switch providers mid-conversation) has no implementation path. Escalation history, context handoff, and the two-tier cache (local vs shared) are all unbuilt. The spool-on-failure pattern for Step 12 (routing-reenvisioned resolved design decision) has no plan.

**Recommendation**: Add a Plan 1.5 or extend Plan 1 with ConversationStore tasks. Dependencies: legion-data (SQLite/PG via Sequel). Schema: `conversations` table (id, created_at, metadata) + `conversation_messages` table (conversation_id, seq, role, content, provider, tokens, timestamp). Hot layer: in-memory LRU. Cold reads: DB on cache miss. Writes: append to in-memory + INSERT (delta, never full rewrite). Spool on DB failure via `Legion::Data::Spool`.

### 2. Streaming -- Pipeline Has No Streaming Path

routing-reenvisioned.md lists streaming as Open Decision #2. The schema spec defines streaming chunks. The provider adapter contract specifies `chat_stream`. But:

- Plan 1's pipeline skeleton has no streaming path
- The Executor calls `session.ask()` (blocking), not `session.stream()`
- No plan addresses how streaming interacts with context store, audit, or RAG enrichment injection
- The existing `chat_stream` on ProviderAdapter is defined but the pipeline has no way to invoke it

**Impact**: The CLI chat already streams via RubyLLM. Wiring it into the new pipeline will either break streaming or force the CLI to bypass the pipeline entirely, defeating the "one entry point" principle.

**Recommendation**: Plan 1 needs a streaming variant of the Executor. Options: (a) `Executor#call_stream` that yields chunks and runs post-response steps on completion, or (b) a StreamingExecutor subclass. Context store and audit should fire on stream completion, not per-chunk. RAG enrichment injection happens before the provider call (Step 8), so it works regardless of streaming.

---

## Important Gaps (Doesn't Block But Creates Drift)

### 3. Step Numbering Mismatch Between Documents

The routing-reenvisioned doc defines a **16-step pipeline**. The unified integration design doc defines an **18-step pipeline**. The plan files follow the 18-step version. Step numbers shifted:

| routing-reenvisioned.md | unified-integration-design.md | Change |
|---|---|---|
| Step 0: Tracing | Step 0: Tracing | same |
| Step 1: UUID | Step 1: Idempotency (NEW) | added |
| -- | Step 2: UUID | renumbered |
| Step 2: Caller Auth | Step 3: Context Load | merged/split differently |
| Step 3: RBAC + Classification | Step 4: RBAC, Step 5: Classification | split into two |
| -- | Step 6: Billing (NEW) | added |

**Impact**: Future sessions referencing "Step 7" will get different answers depending on which doc they read.

**Recommendation**: Add a "Superseded by" note at the top of routing-reenvisioned.md pointing to the unified integration design doc. The reenvisioned doc remains valuable as the conceptual foundation but the design doc is the authoritative step reference.

### 4. Gateway Absorption Teardown Not Explicitly Planned

routing-reenvisioned.md says `lex-llm-gateway` gets **absorbed** into `legion-llm`. Plan 1 mentions gateway absorption in its scope header and has tasks for metering integration (Task 10) and fleet dispatch (Task 11). But there's no explicit task to:

- Deprecate/remove `lex-llm-gateway`
- Update LegionIO's boot sequence to stop loading it
- Remove the `_direct` variant indirection (`chat()` -> gateway -> `chat_direct()`)
- Update `lib/legion/llm.rb` to remove the `begin/rescue LoadError` gateway detection

**Impact**: Two code paths coexist. The gateway delegation pattern (`chat` vs `chat_direct`) becomes confusing when the pipeline already handles metering and fleet dispatch.

**Recommendation**: Add a cleanup task at the end of Plan 1 (or as Plan 1 Task 16) that removes gateway delegation from `legion-llm` and marks `lex-llm-gateway` as deprecated. Don't delete the gateway gem yet -- just stop loading it.

### 5. Provider Adapter Contract Not Implemented

routing-reenvisioned.md defines `ProviderAdapter` with `chat`, `chat_stream`, `capabilities`, `health_check`, `token_estimate`. The current extensions-ai gems (lex-claude, lex-bedrock, etc.) don't implement this interface -- they use RubyLLM under the hood with their own patterns.

Plan 1 Tasks 8-9 (Provider Call steps) delegate to RubyLLM, not to a formal ProviderAdapter. The `ProviderRegistry` described in the reenvisioned doc (`Legion::LLM::ProviderRegistry.get(:claude)`) doesn't exist in any plan.

**Impact**: The pipeline calls RubyLLM directly (works fine), but the clean provider abstraction is aspirational. If you ever want to swap RubyLLM for direct HTTP calls or add a non-RubyLLM provider, this gap matters.

**Recommendation**: Accept this as intentional tech debt for now. The ProviderAdapter contract is the right long-term design but RubyLLM works. Flag for a future plan when provider diversity demands it.

### 6. Error Hierarchy Not Created

routing-reenvisioned.md defines:
```
Legion::LLM::AuthError              -> don't retry, fix credentials
Legion::LLM::RateLimitError         -> retry with backoff
Legion::LLM::ContextOverflow        -> reduce context, retry
Legion::LLM::ProviderError          -> transient, retry
Legion::LLM::ProviderDown           -> circuit breaker, failover
Legion::LLM::UnsupportedCapability  -> route elsewhere
```

Currently only `EscalationExhausted`, `DaemonDeniedError`, `DaemonRateLimitedError` exist. No plan creates the full hierarchy. The pipeline's error handling uses generic `rescue StandardError`.

**Impact**: Circuit breaker logic, retry decisions, and failover all depend on error classification. Without typed errors, the pipeline can't distinguish "retry with backoff" from "don't retry, fix credentials."

**Recommendation**: Add error classes as a small task in Plan 1 Phase A (alongside structs). They're just class definitions -- minimal effort, high value for the provider call step.

### 7. Boot Order GAIA Dependency

Current boot order from MEMORY.md:
```
Logging -> Settings -> Crypt -> Transport -> Cache -> Data -> RBAC -> LLM -> GAIA -> ...
```

The pipeline adds: LLM now needs GAIA (Step 7). GAIA boots **after** LLM.

The design handles this gracefully ("if GAIA unavailable, skip silently"), but GAIA advisory is **never** available for the first N requests until GAIA finishes booting and runs its first tick.

**Impact**: Acceptable for now. First few requests after boot get no GAIA shaping. Worth documenting.

**Recommendation**: No code change needed. Add a note in Plan 2's design that GAIA advisory degrades gracefully during boot and becomes available after GAIA's first tick completes.

---

## Things That Naturally Follow But Aren't Planned

### 8. Teams Bot Migration to Legion::LLM.chat()

The `2026-03-22-teams-rag-bridge.md` idea describes the gap: "Nothing reads traces back to inform LLM responses." Plan 3's RAG read path (Step 8) is exactly the mechanism that would solve this -- if the Teams bot routes through `Legion::LLM.chat()` instead of calling `llm_session.ask()` directly.

**Recommendation**: After Plan 1 is complete, the Teams bot's `handle_message` should switch from direct `llm_session.ask()` to `Legion::LLM.chat()` with proper caller identity. This isn't in any plan but is the natural follow-up. Add to ideas/.

### 9. TBI Phase 5 is Plan 5's Capability Catalog

The design backlog notes TBI Phase 5 (self-generate) and Phase 6 (share protocol) as next items. Plan 5's Capability Catalog is a prerequisite for TBI Phase 5 (self-generated tools need to register in the Catalog). The override confidence mechanism in Plan 5 is essentially TBI learning applied to tool dispatch.

**Recommendation**: Update the TBI status in design-backlog.md to note that Plan 5 covers the foundation for Phase 5. The self-generation loop (lex-codegen + lex-eval generating new tools from observed gaps) remains unplanned but the Catalog gives it a registration target.

### 10. lex-knowledge Escalation Gate -- Superseded

The async-updates-TODO has a full escalation gate design (Phase 3) with small-model/large-model tiering. The new pipeline's routing (explicit -> rules -> smart -> default) with escalation chains completely supersedes this design.

**Recommendation**: Update the async-updates-TODO Phase 3 status to "SUPERSEDED by LLM pipeline routing + escalation chains."

### 11. Caller Authentication Boundary

The routing-reenvisioned doc's Step 2 says "validate credential (JWT, API key, session, mTLS, internal)." The pipeline (Plan 1) trusts the caller identity it receives -- actual credential validation happens upstream at the entry point (daemon API controller, MCP server).

This is probably the right architecture (pipelines shouldn't validate JWTs), but it's a divergence from the reenvisioned doc's description.

**Recommendation**: No code change. Clarify in the design doc that auth happens at entry points, not in the pipeline. The pipeline's RBAC step (Step 4) does authorization ("is this identity permitted?"), not authentication ("is this identity who they claim to be?").

---

## Low Priority / Future

### 12. Fork -- Designed But Unplanned

routing-reenvisioned.md describes fork patterns (comparison, consensus, race) at Steps 7-11. The schema spec has `fork` fields. No plan includes fork implementation. The pipeline Executor has no fork path.

**Impact**: None now. Fork is a power-user feature for model comparison and A/B testing.

**Recommendation**: Track as a future plan. The pipeline architecture supports it (steps 7-11 can execute in parallel per the design) but the Executor needs a fork variant.

### 13. Billing Enforcement

The schema spec has extensive billing fields (`budget_id`, `spending_cap`, `cost`). The design doc has Step 6 (Billing). Plan 1 creates a stub RBAC step but no billing step. The HealthTracker has `budget.daily_limit_usd` and `budget.monthly_limit_usd` listed as "future."

**Impact**: No budget enforcement. Enterprise customers with per-team spending caps have no gate.

**Recommendation**: Track as a separate plan after the core pipeline ships. Billing needs metering data flowing first (Plan 1 Task 10), so it naturally follows.

### 14. Wire Capture

The schema spec defines `wire` capture (raw request/response payloads for translator debugging). Plan 1's Response struct includes `wire` as a field, but no plan implements the opt-in capture mechanism.

**Impact**: Debugging provider translation issues requires manual logging. Low urgency.

**Recommendation**: Implement as needed when debugging a specific provider adapter issue.

### 15. mind_growth Phase 4 (Wiring Loop) Still Blocked

Phase 4.1 (Auto-Wiring) needs `lex-cortex / legion-gaia integration` which is marked NOT STARTED. Plan 2 (GAIA Integration) adds advisory hooks but doesn't address cortex wiring. This remains blocked on cortex work outside the LLM pipeline scope.

### 16. GAS Plan 3 Dependency on Plan 2

Plan 3 (RAG/GAS) has a "soft dependency" on Plan 2 for `llm.audit` exchange and `GaiaCaller`. Without Plan 2:
- GAS subscriber (Task 9) has nothing to listen to
- GAS Phases 3 (Relate) and 4 (Synthesize) fall back to "return empty array"
- Only the RAG read path (Phase A) delivers real value

**Recommendation**: Complete Plan 2 before Plan 3 Phase B (GAS Foundation). Plan 3 Phase A (RAG read path) can proceed independently.

---

## Action Items

| Priority | Item | Where |
|---|---|---|
| P0 | Design ConversationStore (Plan 1.5 or extend Plan 1) | New plan needed |
| P0 | Add streaming path to pipeline Executor | Plan 1 amendment |
| P1 | Add error hierarchy classes | Plan 1 Phase A addition |
| P1 | Add gateway teardown task | Plan 1 tail-end task |
| P1 | Mark routing-reenvisioned.md as superseded | routing-reenvisioned.md header |
| P2 | Clarify auth boundary (entry point vs pipeline) | Design doc note |
| P2 | Update TBI Phase 5 status re: Plan 5 | design-backlog.md |
| P2 | Mark lex-knowledge escalation as superseded | async-updates-TODO.md |
| P2 | Add Teams bot migration to ideas/ | ideas/ |
| P3 | Track fork, billing, wire capture as future | This doc |

---

**This analysis covers all five plans against the full backlog. The two critical gaps (ConversationStore and streaming) should be addressed before Plan 1 is considered complete. Everything else is manageable debt or natural follow-up work.**
