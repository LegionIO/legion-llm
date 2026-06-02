# LLM Audit Pipeline Rearchitecture

**Date:** 2026-06-02
**Status:** Planning
**Author:** Matt Iverson
**Related Issues:** #146, #147

## Problem Statement

86% of `llm_message_inference_requests` rows have `request_json = '{}'`. The current architecture splits audit data across two independent AMQP events (metering + prompt audit) that race to create the same DB rows. The metering event has no request payload; the prompt audit event fires asynchronously and is often lost. Additionally, escalation attempts (multiple upstream provider calls per inbound request) are not individually recorded — only the final outcome is persisted.

Tables `llm_route_attempts`, `llm_policy_evaluations`, and `llm_security_events` exist in the schema but are never populated.

**Compliance impact:** Cannot pass CMS/FedRAMP/HIPAA audit — unable to demonstrate what prompts were sent to which LLM providers.

## Data Model Clarification

| Table | Represents | Cardinality |
|-------|-----------|-------------|
| `llm_message_inference_requests` | Inbound request TO Legion (client asked us to run inference) | 1 per client call |
| `llm_message_inference_responses` | Outbound call FROM Legion to an upstream LLM provider | 1 per escalation attempt |
| `llm_message_inference_metrics` | Token/cost billing for a single upstream call | 1 per response (1:1 with responses) |
| `llm_route_attempts` | Routing decision metadata per attempt (dispatch path, lane, idempotency) | 1 per response |
| `llm_policy_evaluations` | RBAC/classification decision for the request | 1+ per request |
| `llm_security_events` | Security-relevant events (PII detection, blocked calls, policy violations) | 0+ per request |

**Key relationship:** One inbound request → N outbound responses (escalation/lateral). Each response has exactly one metric row and one route_attempt row.

## Architecture: Current vs. Proposed

### Current (broken)

```
Pipeline executes:
  1. step_metering (sync) → emits to llm.metering exchange (no messages in payload)
  2. step_post_response (ASYNC thread) → emits to llm.audit exchange (has messages, often dropped)

Ledger consumers:
  - metering actor → creates request + response + metric rows from metering event (request_json = '{}')
  - prompts actor → creates/enriches request + response + metric rows from audit event (IF it arrives)

Result: whoever wins the race creates the row. Metering usually wins. Audit often lost.
```

### Proposed

```
Pipeline executes (all synchronous, all spool-to-disk on transport failure):
  1. Emit request event BEFORE first provider call (full messages, identity, tools, classification)
  2. Per escalation attempt: emit response event AFTER provider returns (success OR failure)
  3. Emit request status update AFTER all attempts complete

AMQP topology:
  Exchange: llm.audit (topic, durable)
  Routing keys:
    - llm.message.inference.requests  → request_writer actor
    - llm.message.inference.responses → response_writer actor

Legacy (kept for backward compat with older legion-llm nodes):
  - llm.metering exchange + metering actor (still processes old-format events)
  - llm.audit.prompts queue + prompts actor (still processes old-format audit events)
```

## Event Schemas

### Event: Request Opened (routing key: `llm.message.inference.requests`)

Emitted **synchronously before the first provider dispatch**. Priority: HIGH (8).

```ruby
{
  event_type:             'request.opened',
  request_id:            'req_...',
  conversation_id:       'conv_...',
  idempotency_key:       'idem_...',
  correlation_id:        '...',
  exchange_id:           'exch_...',

  # Full request payload (compliance-critical)
  messages:              [...],   # Array of {role:, content:} — the actual prompt
  request_type:          'chat',
  operation:             'chat',

  # Identity & access
  caller:                { requested_by: { identity: '...', type: 'human', credential: 'entra_delegated' } },
  identity:              { identity: '...', type: 'human' },
  classification_level:  'internal',
  access_scope:          'global',

  # Context metadata
  context_message_count: 21,
  context_tokens:        49676,
  token_budget:          0,
  injected_tool_count:   55,
  tool_names:            [...],
  curation_strategy:     'full',

  # Routing intent
  intent:                { capability: :chat, privacy: :normal },
  escalation_chain:      [{ provider: :openai, model: 'gpt-5.4' }, ...],

  # Capture
  request_content_hash:  'sha256:...',
  request_capture_mode:  'full',

  # Timestamps
  requested_at:          '2026-06-02T12:31:19Z',
  recorded_at:           '2026-06-02T12:31:19Z'
}
```

### Event: Request Status Update (routing key: `llm.message.inference.requests`)

Emitted **synchronously after all attempts complete**. Priority: LOW (2).

```ruby
{
  event_type:       'request.closed',
  request_id:       'req_...',
  status:           'responded',        # or 'exhausted', 'error'
  winning_attempt:  2,                   # which attempt_no succeeded (nil if exhausted)
  total_attempts:   3,
  total_wall_clock_ms: 1095,
  recorded_at:      '2026-06-02T12:31:20Z'
}
```

### Event: Response Attempt (routing key: `llm.message.inference.responses`)

Emitted **synchronously after EACH provider call returns** (success or failure). Priority: HIGH (8).

```ruby
{
  event_type:          'response.attempt',
  request_id:          'req_...',        # FK to request
  response_id:         'resp_...',       # unique per attempt
  conversation_id:     'conv_...',
  attempt_no:          1,                # 1-indexed within the escalation chain

  # Provider details
  provider:            'anthropic',
  provider_instance:   'env',
  model_key:           'claude-sonnet-4-6',
  tier:                'frontier',
  dispatch_path:       'direct',         # or 'fleet'

  # Outcome
  status:              'error',          # or 'success'
  finish_reason:       nil,              # 'end_turn', 'tool_use', 'max_tokens'
  error_category:      'InvalidRoleError',
  error_code:          nil,
  error_message:       'Expected role to be one of: system, user, assistant, tool',

  # Tokens & cost (from provider response — even on failure if partially streamed)
  input_tokens:        4124,
  output_tokens:       370,
  thinking_tokens:     0,
  total_tokens:        4494,
  cached_input_tokens: 0,
  cache_creation_tokens: 0,
  cost_usd:            0.005234,
  currency:            'USD',

  # Timing
  latency_ms:          2476,             # provider call time only
  wall_clock_ms:       6790,             # including queue/prep time
  started_at:          '2026-06-02T12:31:20Z',
  ended_at:            '2026-06-02T12:31:22Z',

  # Response content (if success)
  response_content:    '...',            # assistant message content
  response_thinking:   nil,              # thinking block if present
  response_content_hash: 'sha256:...',
  response_capture_mode: 'full',
  tool_calls:          [],               # tool calls in the response

  # Route attempt metadata
  route_target:        'anthropic:env:claude-sonnet-4-6',
  idempotency_key:     'idem_...',
  selected_lane:       nil,              # fleet lane if fleet dispatch
  escalation_context:  { move: 'lateral', from_provider: 'openai', from_model: 'gpt-5.4' },

  # Identity & billing
  caller:              { ... },
  identity:            { ... },
  billing:             { cost_center: '...', budget_key: '...' },
  access_scope:        'global',

  # Timestamps
  recorded_at:         '2026-06-02T12:31:22Z'
}
```

## Emission Points in legion-llm

### Where events fire in the executor pipeline:

```
call() / call_stream()
  │
  ├── execute_pre_provider_steps()
  │     └── [rbac, classification, billing, routing, tool_discovery, etc.]
  │
  ├── ★ EMIT: request.opened  (here — all pre-steps done, payload assembled, before dispatch)
  │
  ├── run_provider_call_with_escalation()
  │     └── escalation_chain.each do |resolution|
  │           ├── attempt_escalation(resolution)
  │           │     ├── dispatch to provider
  │           │     ├── ★ EMIT: response.attempt (success or failure — immediately after return)
  │           │     └── break if success
  │           └── next resolution
  │
  ├── ★ EMIT: request.closed  (here — all attempts done, final status known)
  │
  └── execute_post_provider_steps()
        └── [context_store, knowledge_capture, response_return]
        └── (post_response audit + metering steps become NO-OPs with feature flag)
```

### Non-pipeline paths (`chat_direct`, `chat_single_native`, `LLM.ask`):

Same events, emitted from the non-pipeline call path:
- `request.opened` before `Call::Dispatch.call`
- `response.attempt` after provider returns
- `request.closed` after the call

## Ledger Architecture (lex-llm-ledger)

### New Actors

| Actor | Queue | Routing Key | Runner Function | Prefetch |
|-------|-------|-------------|----------------|----------|
| `RequestWriter` | `llm.audit.request_writer` | `llm.message.inference.requests` | `write_request_record` | 4 |
| `ResponseWriter` | `llm.audit.response_writer` | `llm.message.inference.responses` | `write_response_record` | 4 |

### Runner: write_request_record

```ruby
def write_request_record(payload)
  case payload[:event_type]
  when 'request.opened'
    insert_or_update_request(payload)  # INSERT with full messages; ON CONFLICT update if richer
  when 'request.closed'
    update_request_status(payload)     # UPDATE status, total_attempts, winning_attempt
  end
end
```

### Runner: write_response_record

```ruby
def write_response_record(payload)
  # One event writes to three tables in a single transaction:
  db.transaction do
    response = insert_response(payload)          # llm_message_inference_responses
    insert_metric(payload, response)             # llm_message_inference_metrics
    insert_route_attempt(payload, response)      # llm_route_attempts
  end
end
```

### Legacy actors (unchanged, kept for backward compat)

- `Prompts` actor — still consumes `llm.audit.prompts`, still runs `write_prompt`
- `Metering` actor — still consumes `llm.metering.write`, still runs `write_metering_record`

These handle events from older legion-llm nodes that haven't upgraded. Once all nodes are on the new version, these queues drain and can be unbound.

## AMQP Message Priorities

| Event | Priority | Rationale |
|-------|----------|-----------|
| `request.opened` | 8 (high) | Compliance-critical, has the actual prompt data |
| `response.attempt` | 8 (high) | Billing-critical, has tokens/cost/provider data |
| `request.closed` | 2 (low) | Just a status flip, not data-loss-critical |

## Spool-to-Disk Guarantee

ALL events spool to disk if AMQP transport is unavailable:
- Spool path: `~/.legionio/data/spool/audit/events.jsonl`
- Thread-safe (mutex-protected)
- Flushed when transport reconnects (existing `spool_flush` actor pattern)
- Max spool size configurable (default: 50,000 events)

The existing spool mechanism in `Legion::LLM::Metering` is extracted into a shared `Legion::LLM::EventSpool` module used by both audit and metering emission.

## Migration Strategy

### Phase 1: Emit new events (legion-llm)

- Add new emission points in executor (request.opened, response.attempt, request.closed)
- Keep existing step_metering and step_post_response running (dual-emit during transition)
- Feature flag: `Legion::Settings[:llm][:audit][:emit_v2]` (default: true for new installs)
- Spool-to-disk for all audit events

### Phase 2: New consumers (lex-llm-ledger)

- Add `RequestWriter` and `ResponseWriter` actors with new queues bound to `llm.audit`
- These process new-format events and write to existing tables
- Old actors still run, still process legacy events
- Both can process the same request (idempotent insert-or-update prevents duplicates)

### Phase 3: Deprecate legacy path

- Remove `step_metering` and `step_post_response` from executor (or make them no-ops)
- Metering actor stops creating request/response rows (metrics-only or fully deprecated)
- Prompts actor deprecated (unbind queue)
- Remove dual-emit

### Phase 4: Populate empty tables

- `llm_route_attempts` — populated by response_writer from day 1
- `llm_policy_evaluations` — new emission from `step_rbac` and `step_classification`
- `llm_security_events` — new emission from classification scan, PII detection, tool policy blocks

## Testing Strategy

- Unit specs for new event builders (schema validation)
- Integration specs: executor emits correct events at correct points
- Ledger specs: runners handle insert-or-update correctly, including out-of-order delivery
- End-to-end: request → escalation (3 attempts) → verify all rows created correctly
- Backward compat: old-format events still processed by legacy actors

## Schema Changes (new migration)

### `llm_message_inference_requests` — add client provenance columns

```ruby
Sequel.migration do
  up do
    alter_table(:llm_message_inference_requests) do
      add_column :client_ip, String, size: 45, null: true        # IPv4 or IPv6
      add_column :client_user_agent, String, text: true, null: true  # full UA string
    end
  end

  down do
    alter_table(:llm_message_inference_requests) do
      drop_column :client_user_agent
      drop_column :client_ip
    end
  end
end
```

### Populating these fields

For API/Sinatra requests:
- `client_ip` = `request.ip` (Sinatra's resolved client IP)
- `client_user_agent` = `request.user_agent` (raw UA header)
- `runtime_caller_class` = `'Legion::LLM::API'`
- `runtime_caller_client` = formatted string, e.g. `"Kai/1.0.94 (macOS 25.5.0; arm64) Electron/41.7.1"`

These get passed into the request event from the API route handler:

```ruby
# In the /v1/chat/completions route:
executor.call(
  ...,
  metadata: {
    client_ip:         request.ip,
    client_user_agent: request.user_agent,
    runtime_caller_class: 'Legion::LLM::API',
    runtime_caller_client: request.user_agent
  }
)
```

The `request.opened` event includes these and the `request_writer` persists them.

For non-API paths (extensions, internal callers):
- `client_ip` = nil
- `client_user_agent` = nil
- `runtime_caller_class` = the calling extension/module class name
- `runtime_caller_client` = nil or the extension's identifier

## Additional Audit Gaps to Address

### 1. Tool Call Audit (existing `llm_tool_calls` + `llm_tool_call_attempts`)

**Current state:** Tool events emit via `@tool_event_handler` callback and `Legion::LLM::Audit.emit_tools`. The `tools` actor in the ledger consumes these and writes to `llm_tool_calls` + `llm_tool_call_attempts`. This path appears to work but should be verified as part of this work.

**What to include in `request.opened`:**
- `injected_tools` — full list of tool schemas injected (names, sources, count)
- `tool_policy` — what policy governed tool injection (client passthrough, registry, triggered)

**What to include in `response.attempt`:**
- `tool_calls` — array of tool calls the LLM made in this attempt (name, args, id)
- For multi-turn tool loops (native tool loop), each round's tool call/result should be captured

**New event consideration:** `llm.tool.calls` routing key for a dedicated tool audit trail that includes:
- Which tools were available vs. which were called
- Arguments passed (for security review)
- Results returned (for data flow audit)
- Duration per tool call
- Whether the tool was dispatched to MCP, LEX runner, or native execution

### 2. RAG/GAS Context Injection

**Current state:** `step_rag_context` retrieves from Apollo and stores in `@enrichments['rag:context_retrieval']`. This data flows into the audit event's `enrichments` field but is NOT separately tracked.

**What to include in `request.opened`:**
- `rag_strategy` — which retrieval strategy was selected (rag, rag_compact, none)
- `rag_entry_count` — how many knowledge entries were injected
- `rag_sources` — entry IDs/references that were injected (for auditability — "what knowledge influenced this response?")
- `rag_confidence_scores` — per-entry confidence scores

**Why it matters:** If an LLM produces a bad answer based on injected RAG context, auditors need to trace WHICH knowledge entries influenced it.

### 3. GAIA Advisory / Cognitive Shaping

**Current state:** `step_gaia_advisory` calls `Legion::Gaia.advise()` and stores results in `@enrichments['gaia:advisory']`. Includes routing hints, system prompt injection, tool hints, partner observations.

**What to include in `request.opened`:**
- `gaia_advisory_types` — what GAIA contributed (routing_hint, system_prompt, tool_hint, partner_hint)
- `gaia_routing_hint` — if GAIA influenced routing (recommended tier, model override)
- `gaia_system_prompt_injected` — boolean (did GAIA inject a system prompt?)

**Why it matters:** GAIA shapes behavior invisibly. If a request gets routed to a specific provider because GAIA said so, that decision needs to be auditable.

### 4. Enrichment Injector (System Prompt Assembly)

**Current state:** `EnrichmentInjector.inject()` assembles the final system prompt from baseline + GAIA + RAG + skills. The injected content is not separately captured.

**What to include in `response.attempt` (since injection happens per-attempt during escalation):**
- `system_prompt_hash` — SHA256 of the assembled system prompt (don't store full text — it's in the messages)
- `system_prompt_parts` — which sources contributed (baseline, gaia, rag, skill)
- `system_prompt_token_count` — how many tokens the system prompt consumed

### 5. Classification & Policy Evaluation → `llm_policy_evaluations`

**Current state:** `step_classification` scans for PII/PHI and stores in `@enrichments['classification:scan']` and `@audit`. `step_rbac` authorizes and records outcome. Neither writes to `llm_policy_evaluations`.

**New: Include in `request.opened`:**
- `classification` block with: declared_level, effective_level, contains_pii, contains_phi, detected_patterns, upgraded
- `rbac_decision` — permit/deny/fail_open, principal, caller_id

**New event or field for `llm_policy_evaluations`:**
The `request_writer` should write a `llm_policy_evaluations` row from the classification + rbac data in the `request.opened` event. One row per policy evaluation (could be 2: one for classification, one for RBAC).

### 6. Security Events → `llm_security_events`

**Current state:** Table exists, never populated. Should be written when:
- Classification detects PII/PHI (event_type: 'pii_detected' or 'phi_detected')
- RBAC denies a request (event_type: 'access_denied')
- A tool call is blocked by policy (event_type: 'tool_blocked')
- Cloud tier is blocked due to enterprise privacy (event_type: 'privacy_block')
- Content redaction occurs (event_type: 'content_redacted')

**Implementation:** The `request_writer` and `response_writer` check for security-relevant conditions in the event payload and insert `llm_security_events` rows as a side-effect. No separate AMQP event needed — the data is already in the request/response events.

### 7. Escalation Chain Decision Audit

**Current state:** `@escalation_history` is populated during escalation. Route attempts are captured in `@route_attempts`. Neither is persisted to dedicated tables.

**What `response.attempt` carries (already in the schema above):**
- `attempt_no` — position in escalation chain
- `escalation_context` — why this attempt happened (move: primary/lateral/escalation, from_provider, from_model)

**What `request.closed` carries:**
- `total_attempts` — how many providers were tried
- `winning_attempt` — which attempt_no succeeded
- Full escalation chain that was planned (from router)

This data flows into `llm_route_attempts` rows written by the `response_writer`.

### Summary: What each event carries for audit completeness

| Field Category | `request.opened` | `response.attempt` | `request.closed` |
|---------------|------------------|-------------------|-----------------|
| Messages/prompt | ✅ full | ❌ | ❌ |
| Identity/caller | ✅ | ✅ | ❌ |
| Client IP/UA | ✅ | ❌ | ❌ |
| Classification/PII | ✅ | ❌ | ❌ |
| RBAC decision | ✅ | ❌ | ❌ |
| Tool injection list | ✅ | ❌ | ❌ |
| RAG context refs | ✅ | ❌ | ❌ |
| GAIA advisory | ✅ | ❌ | ❌ |
| Escalation chain plan | ✅ | ❌ | ❌ |
| Provider/model/tier | ❌ | ✅ | ❌ |
| Tokens/cost | ❌ | ✅ | ❌ |
| Response content | ❌ | ✅ | ❌ |
| Tool calls made | ❌ | ✅ | ❌ |
| Error details | ❌ | ✅ | ❌ |
| Latency/timing | ❌ | ✅ | ❌ |
| System prompt hash | ❌ | ✅ | ❌ |
| Final status | ❌ | ❌ | ✅ |
| Winning attempt | ❌ | ❌ | ✅ |
| Total wall clock | ❌ | ❌ | ✅ |

## Streaming Response Semantics

For streaming requests (`call_stream`), `response.attempt` emits **once at stream completion** (when the provider sends the final usage/done event). This means:

- `latency_ms` = time from dispatch to first token (captured separately as `time_to_first_token_ms`)
- `wall_clock_ms` = time from dispatch to stream end (includes provider generation time)
- `output_tokens` / `cost_usd` = final values from the provider's usage block (sent at stream end)
- `response_content` = full accumulated content

If the stream dies mid-way (provider error, connection drop, timeout):
- `response.attempt` still emits with `status: 'error'`
- `output_tokens` = partial count if the provider reported usage before dying, otherwise 0
- `error_message` = the failure reason
- `response_content` = whatever was accumulated before failure (may be partial)

No separate `response.streaming.started` / `response.streaming.completed` events. One event per attempt, always at termination (success or failure). The `time_to_first_token_ms` field distinguishes "fast start, slow generation" from "slow provider."

## Spool Overflow Policy

When the spool reaches capacity (default: 50,000 events):

1. **Alert at 80% capacity** — emit a `Legion::Events` warning: `llm.audit.spool_pressure` with current count
2. **Alert at 95% capacity** — emit a critical alert: `llm.audit.spool_critical`
3. **At 100% — reject new LLM requests** — return 503 to callers with message "Audit spool full — LLM requests blocked until transport reconnects"

**Rationale:** For HIPAA/FedRAMP, silently dropping audit events is a finding. Silently dropping request data is also a finding. Blocking requests is an operational impact but NOT a compliance failure — it's a compensating control that preserves the invariant "every LLM call has an audit trail."

The spool file path, max size, and overflow behavior are configurable:
```ruby
Legion::Settings[:llm][:audit][:spool] = {
  max_events:          50_000,
  warn_threshold:      0.8,
  critical_threshold:  0.95,
  overflow_policy:     :block_requests  # or :drop_oldest (non-compliant)
}
```

## Consumer Error Handling (Ledger Runner DLQ)

When `write_request_record` or `write_response_record` fails:

1. **Transient DB errors** (connection timeout, pool exhausted): NACK with requeue. Bunny redelivers after channel recovery. Max 3 redeliveries (tracked via `x-delivery-count` header on quorum queues).
2. **Persistent errors** (constraint violation, data format): NACK without requeue → message goes to **dead letter queue** (`llm.audit.request_writer.dlq` / `llm.audit.response_writer.dlq`).
3. **DLQ monitoring**: A periodic actor (`DlqMonitor`) checks DLQ depth every 60s and emits `Legion::Events` alert if non-empty.
4. **DLQ replay**: Manual replay via `legionio ledger replay-dlq <queue_name>` CLI command after the underlying issue is fixed.

Queue declarations:
```ruby
queue_options: {
  durable: true,
  arguments: {
    'x-queue-type': 'quorum',
    'x-delivery-limit': 3,
    'x-dead-letter-exchange': 'llm.audit.dlq',
    'x-dead-letter-routing-key': 'dlq.request_writer'
  }
}
```

## Embedding Call Audit

`embed()`, `embed_batch()`, and `embed_direct()` are LLM provider calls that consume tokens and may contain PHI (clinical search queries). They MUST be audited.

**Event:** `response.attempt` with `operation: 'embed'` (same routing key, same consumer).

Emitted from:
- `Call::Embeddings.generate` — after provider returns
- `Call::Embeddings.generate_batch` — one event per batch (not per text)

**Fields specific to embedding:**
- `operation: 'embed'`
- `input_text_chars: 1507` (length of input, not the full text for privacy)
- `input_chunks: 2` (how many chunks were embedded)
- `dimensions: 1024` (output vector size)
- No `response_content` (embeddings are vectors, not text)
- `input_tokens` / `cost_usd` from provider response

**No `request.opened` for embeddings** — they're always sub-operations of a larger request (RAG retrieval, knowledge ingestion). The parent request's `request.opened` already captures the intent. Embedding `response.attempt` events link via `parent_request_id` when available.

## Dual-Emit Deduplication Strategy

During Phase 2 (both old and new actors running):

**Dedup key:** `(request_ref, attempt_no)` for responses, `(request_ref)` for requests.

**Rules:**
1. New `response_writer` uses `response_id` (a UUID generated at emit time) as the unique key for `llm_message_inference_responses`. Old metering actor uses `stable_uuid(request_ref)`. These are DIFFERENT UUIDs → no conflict, but creates duplicate rows.
2. To prevent this: **old metering actor does NOT create response rows during Phase 2**. It only writes to `llm_message_inference_metrics` (its original purpose). This requires a one-line change in the metering runner: skip `find_or_create_request` and `find_or_create_response`, only call `find_or_create_metric` if a response row already exists.
3. The old prompts actor continues to work for `msg_*` requests from older nodes. The new `request_writer` handles `request.opened` events. Both use `request_ref` as the conflict key — ON CONFLICT DO NOTHING (first writer wins).

**Reconciliation query** (run periodically by `reconciliation` actor):
```sql
-- Find requests with metrics but no response (orphaned by old metering actor)
SELECT m.id, m.message_inference_request_id
FROM llm_message_inference_metrics m
LEFT JOIN llm_message_inference_responses r ON r.id = m.message_inference_response_id
WHERE r.id IS NULL AND m.inserted_at > NOW() - INTERVAL '1 day';
```

## Failed Attempt Metrics

Every `response.attempt` gets a metric row, regardless of outcome:
- **Success:** Full token counts and cost from provider
- **Error with partial streaming:** Whatever tokens the provider reported before dying
- **Connection refused / timeout before any data:** `input_tokens: 0, output_tokens: 0, cost_usd: 0.0`
- **InvalidRoleError (fails before sending to provider):** `input_tokens: 0, output_tokens: 0, cost_usd: 0.0`

The metric row is ALWAYS created (1:1 with response rows). Billing queries filter on `cost_usd > 0` for spend reports. The zero-cost rows are still valuable for failure rate analysis and provider health tracking.

## Multi-Round Tool Loop Events

Within a single request, the native tool loop dispatches to the provider N times. Each dispatch is a `response.attempt` with:

- `attempt_type: 'tool_round'` (not 'escalation')
- `tool_round: 1` (1-indexed within the tool loop)
- `tool_calls: [{name, arguments, id}]` — tool calls the LLM made this round
- `tool_results_pending: true` — indicates more rounds may follow
- Same `request_id`, incrementing `attempt_no` globally

The final round has `tool_results_pending: false` and `finish_reason: 'end_turn'`.

This means a request with 3 tool rounds + 1 escalation retry = 4 response rows:
- attempt_no=1, tool_round=1, attempt_type='tool_round', status='tool_use'
- attempt_no=2, tool_round=2, attempt_type='tool_round', status='tool_use'
- attempt_no=3, tool_round=3, attempt_type='tool_round', status='end_turn' (success)
- OR: attempt_no=3, attempt_type='escalation' if the tool loop failed and escalated

## Response Writer Transaction Strategy

The 3-table write is split to prevent blast radius:

```ruby
def write_response_record(payload)
  response = insert_response(payload)  # independent, must succeed
  insert_metric(payload, response)     # independent, logs warning on failure
  insert_route_attempt(payload, response)  # independent, logs warning on failure
end
```

Each insert is its own savepoint. If `insert_route_attempt` fails (table doesn't exist on an older schema), the response and metric rows are preserved. Failures log at WARN level and do NOT nack the message.

## Index Strategy

Indexes required for the new query patterns:

```sql
-- Already exist (verify):
CREATE INDEX IF NOT EXISTS idx_requests_request_ref ON llm_message_inference_requests(request_ref);
CREATE INDEX IF NOT EXISTS idx_responses_request_id ON llm_message_inference_responses(message_inference_request_id);
CREATE INDEX IF NOT EXISTS idx_metrics_response_id ON llm_message_inference_metrics(message_inference_response_id);

-- New (add in migration):
CREATE INDEX idx_responses_attempt_no ON llm_message_inference_responses(message_inference_request_id, attempt_no);
CREATE INDEX idx_route_attempts_request_id ON llm_route_attempts(message_inference_request_id);
CREATE INDEX idx_requests_conversation_inserted ON llm_message_inference_requests(conversation_id, inserted_at DESC);
CREATE INDEX idx_responses_provider_inserted ON llm_message_inference_responses(provider, inserted_at DESC);
```

## Identity & Billing Field Clarification

| Field | Meaning | Used for |
|-------|---------|----------|
| `caller` | The code path that initiated the request (extension name, API route, GAIA mode) | Debugging, attribution |
| `identity` | The human or system principal whose spend this counts against | **Billing, cost center allocation** |
| `caller.requested_by.identity` | Same as `identity` when available | Redundant, for backward compat |

**Billing rule:** `identity.identity` drives cost center allocation. If a GAIA tick runs on behalf of user `kblanc13`, the identity is `kblanc13` even though the caller is `lex-agentic-language`.

## Data Retention

| Table | Retention | Purge policy |
|-------|-----------|-------------|
| `llm_message_inference_requests` | 90 days default, 30 days if contains_phi | `retention_purge` actor, configurable via `settings[:llm][:compliance][:retention]` |
| `llm_message_inference_responses` | Same as parent request | Cascade delete from request |
| `llm_message_inference_metrics` | 365 days (billing) | Separate purge, preserves aggregated rollups |
| `llm_route_attempts` | Same as parent request | Cascade delete |
| `llm_policy_evaluations` | 365 days | Independent purge |
| `llm_security_events` | 7 years (compliance) | Never auto-purged, manual archival only |

## Schema Migration Approach

New fields from the event schema that don't have existing columns are stored in the existing `request_json` / `response_json` TEXT columns (JSON-encoded). The typed columns (`provider`, `model_key`, `tier`, `status`, etc.) continue to be populated directly.

New columns added in this work:
- `llm_message_inference_requests`: `client_ip` (varchar 45), `client_user_agent` (text)
- `llm_message_inference_responses`: `attempt_no` (integer, default 1), `attempt_type` (varchar 32), `tool_round` (integer, null)
- `llm_message_inference_metrics`: `time_to_first_token_ms` (integer, null)

All other event fields (enrichments, timeline, tracing, etc.) go into `request_json` / `response_json` as before.

## Backfill Decision

The 57,779 existing `request_json = '{}'` rows **cannot be recovered** — the audit events are gone. Compensating control: add a `data_quality_flag` column (varchar 32) to `llm_message_inference_requests`. Backfill sets it to `'incomplete'` for all existing `{}` rows. New rows get `'complete'`. Compliance reports filter on `data_quality_flag = 'complete'` and document the gap with a formal exception noting the date range and root cause fix.

## Adversarial Review Round 2 — Resolutions

### 🔴 #1: request.opened misses denied/blocked requests

**Resolution: Two-event model for requests.**

- `request.received` — fires at the TOP of `execute_steps`, before any pre-provider step. Contains: identity, raw messages, client_ip, user_agent, request_id, timestamp. Lightweight — just "someone asked us to do something."
- `request.opened` — fires after pre-steps complete, before dispatch. Contains: full assembled payload with classification, tools, routing intent, escalation chain.

If RBAC denies, classification blocks, or budget rejects — the `request.received` row exists with status `'denied'` or `'blocked'`. The `request.opened` event fires as a status update to that row (or never fires, and the row stays at `'received'`).

The `request_writer` runner handles all three: `request.received` (INSERT), `request.opened` (UPDATE with full payload), `request.closed` (UPDATE with final status).

Priority: `request.received` = 9 (highest — must always land), `request.opened` = 8, `request.closed` = 2.

### 🔴 #2: after_chat metering hook bypasses executor

**Resolution: Decommission the hook in Phase 1.**

`Legion::LLM::Hooks::Metering.install` registers an `after_chat` hook that emits via the old metering path. In Phase 1, when v2 events are enabled:
- The hook is NOT installed (guarded by `unless Legion::Settings.dig(:llm, :audit, :emit_v2)`)
- The v2 emission points in the executor replace it entirely

For non-pipeline paths (`chat_single_native`, `chat_direct`), the v2 `response.attempt` emission is added directly in those methods — they don't need the hook.

### 🔴 #3: Response UUID collision on same-provider escalation

**Resolution: v2 events use emit-time UUIDs, not deterministic hashes.**

The old `stable_uuid("response:#{request_ref}:#{provider}")` dedup key is broken for escalation. The new `response_writer` uses `response_id` (a `SecureRandom.uuid` generated at emit time in the executor) as the primary key. Dedup is on `(request_ref, attempt_no)` compound unique index — not UUID.

The old `find_or_create_response` with its deterministic UUID is only used by the legacy prompts actor (Phase 2 backward compat). It cannot collide with v2 rows because they use different UUID namespaces.

### 🔴 #4: Metric UUID is 1:1 with request, not attempt

**Resolution: Metric UUID includes response_id.**

New dedup key: `"metric:#{response_id}"` — one metric per response row, guaranteed unique per attempt.

The old path (`"metric:#{request_ref}"`) remains for legacy metering actor only. During Phase 2, if the old actor creates a metric and the new actor also creates one for the same request (different response_id), both coexist. The reconciliation actor merges them post-Phase 3.

### 🔴 #5: Standalone embedding calls lack request context

**Resolution: Standalone embeddings get their own `request.received` event.**

When `Call::Embeddings.generate` is called OUTSIDE a pipeline request (no `@request` context):
- Generate a synthetic `request_id` = `"embed_#{SecureRandom.hex(12)}"`
- Emit `request.received` with `operation: 'embed'`, the caller identity (from thread-local or passed explicitly), and input metadata (text_chars, chunks)
- Emit `response.attempt` with `operation: 'embed'` after provider returns

When called INSIDE a pipeline (RAG step, etc.): link via `parent_request_id` to the enclosing request. No separate `request.received`.

### 🔴 #6: Async step_post_response during Phase 2 dual-emit

**Resolution: Phase 1 moves `post_response` out of ASYNC_SAFE_STEPS immediately.**

This is the one-line fix from issue #146:
```ruby
ASYNC_SAFE_STEPS = %i[knowledge_capture response_return].freeze  # post_response REMOVED
```

This happens in Phase 1, BEFORE v2 events are added. It fixes the 93% → 100% success rate for `msg_*` requests immediately. The v2 events then replace `step_post_response` entirely in Phase 3.

### 🟠 #7: request_json stores array vs object inconsistency

**Accepted as-is.** The `request_json` column stores the messages array `[{...}]` for the new system. This is valid JSON. Downstream queries should use `request_json::jsonb` (cast to JSONB) and `jsonb_array_elements` for message-level queries. The column is a compliance artifact (verbatim what was processed), not a queryable document store. Adding a note to the schema docs.

### 🟠 #8: deep_symbolize on payload

**Accepted as-is.** `Legion::JSON.dump` handles symbol keys correctly (converts to strings in output). Time objects are serialized via `.iso8601` by `Legion::JSON`'s encoder. This is tested in existing specs and not a new risk.

### 🟠 #9: No schema validation in request_writer

**Resolution: Add event_type validation with unknown-type alerting.**

```ruby
def write_request_record(payload)
  case payload[:event_type]
  when 'request.received'  then insert_request(payload)
  when 'request.opened'    then update_request_payload(payload)
  when 'request.closed'    then update_request_status(payload)
  else
    log.error("[request_writer] unknown event_type=#{payload[:event_type]} request_id=#{payload[:request_id]}")
    # NACK without requeue → DLQ for investigation
  end
end
```

Required field validation (request_id, event_type, timestamp) happens before the case statement. Missing required fields → DLQ.

### 🟠 #10: Embed responses produce response_json = '{}'

**Resolution: Embed responses don't write to response_json.**

For `operation: 'embed'`, the `response_writer` skips `response_json` and `response_content_hash`. Instead it writes:
- `status: 'success'` or `'error'`
- `input_tokens` / `cost_usd` (in the linked metric row)
- `provider`, `model_key`, `tier`
- `latency_ms`, `wall_clock_ms`

No response_json is expected or written. The column stays NULL (not `{}`). NULL means "not applicable for this operation type." `{}` means "should have data but doesn't."

### 🟠 #11: @escalation_history never written to any table

**Resolution: Escalation history is reconstructable from response.attempt rows.**

Each `response.attempt` carries `escalation_context: { move: 'lateral', from_provider: '...', from_model: '...' }`. The full chain is recoverable by querying all response rows for a request_id ordered by attempt_no. No separate "escalation history" event needed — the data is there per-attempt.

The `request.opened` event carries `escalation_chain: [...]` (the planned chain from the router). Comparing planned vs actual (from response rows) gives the full picture.

### 🟠 #12: Spool overflow keeps newest — can orphan paired events

**Resolution: Spool overflow blocks requests (never drops events).**

Per the spool overflow policy defined above: at 100% capacity, new LLM requests are BLOCKED (503). Events are never dropped from the spool. The "keeps newest" trimming behavior in the old metering spool is NOT used by the new `EventSpool`. The new spool is append-only until flushed or until the overflow policy triggers.

### 🟠 #13: Per-process spool on ephemeral storage

**Resolution: Document as known limitation with mitigation.**

For containerized deployments:
- Spool path MUST be configured to a persistent volume (`/var/lib/legionio/spool/` mounted as PVC)
- If ephemeral storage is used, the overflow policy `:block_requests` prevents data loss (requests fail rather than losing audit)
- For ECS/EKS without PVC: use the `:block_requests` policy AND set spool max low (1000) so transport outages surface immediately as request failures rather than silently accumulating

Added to deployment docs, not the architecture doc.

### 🟡 #14-15: No per-round/per-attempt emission points in executor code

**Acknowledged — this is implementation work, not a design gap.** The design doc specifies WHERE events emit. The implementation plan will detail the code changes needed in `native_tool_loop.rb` (inject after each `dispatch_provider_request`) and `executor.rb#attempt_escalation` (inject after `execute_provider_request` returns).

### 🟡 #16: llm_messages table duplicates conversation state

**Out of scope.** The `llm_messages` table is owned by the ledger for audit persistence. The in-memory `Conversation` store is for runtime context management. They serve different purposes (audit vs. runtime) and intentional divergence is acceptable.

### 🟡 #17: current_turn_messages truncates system prompt

**Resolution: System prompt is stored separately.**

The `request.opened` event carries `system_prompt_hash` (from `response.attempt`) AND the full system prompt is available in `enrichments['gaia:system_prompt']` within the event payload. The `current_turn_messages` truncation is for the MESSAGES field only. The system prompt injected by `EnrichmentInjector` is captured in `request_json` at insert time (it's the first message in the array before truncation applies).

Additionally: `audit_max_messages` defaults to 20 which covers the system prompt for most conversations. For long conversations, the hash provides tamper-evidence.

### 🟡 #18: Metering.emit swallows exceptions without spooling

**Resolution: Fix in Phase 1 — emit exceptions trigger spool.**

```ruby
def emit(event)
  event = attributed_event(event)
  event_class = metering_event_class if transport_connected?
  if event_class
    event_class.new(**event).publish
    :published
  else
    spool_event(event)
    :spooled
  end
rescue StandardError => e
  spool_event(event)  # <-- spool on ANY failure, not just transport-down
  handle_exception(e, level: :warn, operation: 'llm.audit.emit')
  :spooled
end
```

### 🟡 #19-20: Reconciliation ambiguous join + dual-emit enrichment skip

**Resolution: These are Phase 2 transitional issues that self-resolve in Phase 3.** The reconciliation query is improved to match on `(conversation_id, request_ref, inserted_at within 5s)`. The enrichment skip during dual-emit is acceptable — v2 data wins in Phase 3 when old actors are removed.

### 🟢 #21-23: Spool size mismatch, log.unknown, debug PHI logging

- #21: New `EventSpool` uses 50K default. Old metering spool stays at 10K until decommissioned. No conflict — they're separate files.
- #22: `log.unknown` removed (bug, not design).
- #23: The debug logging (`log.error payload`) was temporary instrumentation added during this investigation session. It MUST be removed before any commit. Not part of the design.

## Resolved Design Decisions

1. `llm_policy_evaluations` — populated in Phase 2 (part of this work). The data is already in `request.opened`.
2. Backfill — formal exception with `data_quality_flag` column, not a backfill job.
3. `llm.metering` exchange — formally deprecated in Phase 3. Left operational in Phase 2 for backward compat but metering actor stops creating request/response rows.
4. Three-event model: `request.received` (at entry) → `request.opened` (after pre-steps) → `request.closed` (after all attempts).
5. Async `post_response` fix (issue #146) ships in Phase 1 as an immediate fix, independent of v2 events.
6. `after_chat` metering hook decommissioned in Phase 1 (guarded by feature flag).

## Adversarial Review Round 3 — Resolutions

### 🔴 #1: Inference.call path bypasses executor — zero v2 events

**Resolution: All paths MUST go through the executor.**

The current `Inference.call` (inference.rb:370-393) dispatches directly without the executor pipeline. This is the legacy "quick" path that extensions and hooks use. In Phase 1:

- `Inference.call` is deprecated. All callers are migrated to `Inference.chat` (which uses the executor).
- For callers that need the lightweight path (no RAG, no tools, no classification), use `Inference::Profile::SYSTEM` which skips non-essential steps but STILL runs through the executor's emission points.
- The executor profiles already support step skipping: `GAIA_SKIP`, `SYSTEM_SKIP`, `QUICK_REPLY_SKIP`. The emission steps (`request.received`, `response.attempt`, `request.closed`) are NEVER skipped — they're not in any skip list.

For the transition period: `Inference.call` wraps the executor with `profile: :system` internally, so existing callers get v2 events without code changes:

```ruby
def call(messages:, model:, provider:, **)
  Executor.new(Request.build(messages: messages, model: model, provider: provider, **), profile: :system).call
end
```

### 🔴 #2: Two separate after_chat hooks

**Resolution: Consolidate to ONE metering path, guarded by one flag.**

`Hooks::Metering` (hooks/metering.rb) is dead code — it's never installed by `install_defaults`. It exists as an unused module. Phase 1 deletes the file entirely. Only `Legion::LLM::Metering.install_hook` (called from `Hooks.install_defaults`) is active, and it's guarded:

```ruby
def install_defaults
  unless Legion::Settings.dig(:llm, :audit, :emit_v2)
    Legion::LLM::Metering.install_hook
  end
  Hooks::BudgetGuard.install
end
```

Verified: `grep -rn "Hooks::Metering.install"` across the entire monorepo shows zero callers outside the module definition itself.

### 🔴 #3: flush_spool truncates before publish completes

**Resolution: Atomic flush with published-offset tracking.**

New flush mechanism:
1. Read spool file line by line
2. Publish each event to AMQP with publisher confirms enabled
3. After EACH confirmed publish, write the line offset to a `.cursor` file (`events.jsonl.cursor`)
4. After all lines are published and confirmed, truncate the spool file and reset cursor to 0
5. On crash/restart: read cursor → skip already-published lines → resume from cursor position

```ruby
def flush_spool
  cursor = read_cursor
  lines = File.readlines(spool_path)
  lines[cursor..].each_with_index do |line, i|
    event = Legion::JSON.load(line)
    publish_with_confirm(event)
    write_cursor(cursor + i + 1)
  end
  truncate_spool
  reset_cursor
end
```

No event is lost on crash — the cursor file persists the last-published offset.

### 🔴 #4: request.opened arriving before request.received

**Resolution: All event handlers do INSERT-or-UPDATE (upsert), not conditional logic.**

```ruby
def write_request_record(payload)
  case payload[:event_type]
  when 'request.received'
    upsert_request(payload, initial: true)
  when 'request.opened'
    upsert_request(payload, initial: false)
  when 'request.closed'
    upsert_request(payload, initial: false)
  end
end

def upsert_request(payload, initial:)
  db[:llm_message_inference_requests].insert_conflict(
    target: :request_ref,
    update: build_update_fields(payload, initial: initial)
  ).insert(build_insert_fields(payload))
end
```

If `request.opened` arrives first: INSERT succeeds (creates the row with full payload). When `request.received` arrives later: ON CONFLICT updates only NULL fields (doesn't overwrite existing data). The `initial: true` flag on `request.received` means it can set fields that later events won't overwrite (like `received_at` timestamp).

If `request.received` arrives first: INSERT succeeds with raw messages. When `request.opened` arrives: ON CONFLICT updates `request_json` with the full injected payload, status from 'received' to 'dispatched'.

Either order produces the same final state.

### 🔴 #5: generate_batch — 50 embeddings, same request_id, same attempt_no

**Resolution: generate_batch emits ONE request + ONE response for the batch, not per-item.**

`generate_batch` is a single API call to the provider with multiple texts. The provider returns one response with one token count. It's one billing event:

- `request_id` = `"embed_batch_#{SecureRandom.hex(12)}"` (one per batch call)
- `response.attempt` = one event with `input_chunks: 50`, `input_tokens: <total>`, `cost_usd: <total>`
- `attempt_no` = 1 (always — no escalation for embeddings)

Per-item breakdown is metadata in the response event (`chunk_details: [{index: 0, tokens: 12}, ...]`) but NOT separate rows. One request, one response, one metric — for the batch.

If `generate_batch` internally splits into multiple provider calls (chunking for context limits), each provider call IS a separate `response.attempt` with incrementing `attempt_no` (1, 2, 3...) under the same `request_id`. This matches the escalation model — multiple provider calls for one inbound request.

### 🟠 #6: Partial failure in response_writer (response exists, metric doesn't)

**Resolution: Accepted as eventually consistent. Reconciliation query added.**

The response_writer acks after `insert_response` succeeds. If `insert_metric` fails, the response row exists without a metric. This is acceptable because:
- The message is acked (response data is persisted — the critical compliance artifact)
- A periodic reconciliation query finds orphaned responses and re-derives metrics from the response row's token fields

```sql
-- Reconciliation: find responses without metrics
SELECT r.id, r.message_inference_request_id, r.provider, r.model_key
FROM llm_message_inference_responses r
LEFT JOIN llm_message_inference_metrics m ON m.message_inference_response_id = r.id
WHERE m.id IS NULL AND r.inserted_at > NOW() - INTERVAL '1 day';
```

The `reconciliation` actor runs this hourly and creates missing metric rows.

### 🟠 #7: Raw vs injected messages — where do they live?

**Resolution: Two fields.**

- `request_json` — what was DISPATCHED to the provider (injected messages, system prompt, full context). Set by `request.opened` event. This is the compliance artifact.
- `caller_messages_json` — what the CALLER sent (raw, no injection). Set by `request.received` event. This is for debugging/UX.

New column: `caller_messages_json TEXT NULL` added in migration. The `request_json` column continues to hold the dispatched payload (what the provider saw).

### 🟠 #8: Hooks::Metering.install latent risk

**Invalidated.** Verified via grep — `Hooks::Metering.install` is never called anywhere in the monorepo. The module exists but is dead code. Deleted in Phase 1 cleanup. No latent risk.

### 🟠 #9: Inference.call runs hooks but no v2 events

**Resolved by #1 above.** `Inference.call` wraps the executor with `:system` profile. All paths go through executor. No separate hook-only path exists after Phase 1.

### 🟠 #10: request.opened before request.received — UPDATE on non-existent row

**Resolved by #4 above.** All handlers use upsert. Order doesn't matter.

### 🟡 #11: step_metering and v2 response.attempt — double metric during Phase 2

**Resolution: step_metering is disabled when emit_v2 is true.**

```ruby
def step_metering
  return if v2_audit_enabled?  # skip legacy metering when v2 is active
  # ... existing metering logic
end
```

The old metering actor only receives events from nodes running without emit_v2. New nodes emit response.attempt only. No double metrics.

### 🟡 #12: Crash leaves request.closed unemitted

**Resolution: Reconciliation actor detects orphaned requests.**

A periodic check (every 5 minutes) finds requests in 'dispatched' status older than 5 minutes with no corresponding `request.closed`:

```sql
SELECT id, request_ref FROM llm_message_inference_requests
WHERE status = 'dispatched' AND inserted_at < NOW() - INTERVAL '5 minutes'
AND NOT EXISTS (
  SELECT 1 FROM llm_message_inference_responses
  WHERE message_inference_request_id = llm_message_inference_requests.id
  AND inserted_at > llm_message_inference_requests.inserted_at + INTERVAL '5 minutes'
);
```

These get status set to `'orphaned'` with a note. No fake `request.closed` — the absence IS the audit trail (process crashed).

### 🟡 #13: First attempt has no from_provider in escalation_context

**Accepted.** First attempt: `escalation_context: { move: 'primary' }` with no `from_provider`. Subsequent: `{ move: 'lateral', from_provider: '...' }`. This is schema-correct — `from_provider` is nullable/optional in the JSON. Queries use `escalation_context->>'move'` for counting, not `from_provider`.

### 🟡 #14: attempt_no shared between tool rounds and escalation

**Resolution: Separate counters.**

- `attempt_no` — escalation attempts only (1, 2, 3 across providers)
- `tool_round` — tool loop iterations within ONE attempt (1, 2, 3 within a single provider call)

A request with 2 tool rounds then escalation:
- attempt_no=1, tool_round=1, attempt_type='tool_round'
- attempt_no=1, tool_round=2, attempt_type='tool_round'
- attempt_no=1, tool_round=3, attempt_type='end_turn' (final round, success)

If it escalated instead:
- attempt_no=1, tool_round=1, attempt_type='tool_round' (provider A, tool call)
- attempt_no=1, tool_round=2, attempt_type='error' (provider A failed)
- attempt_no=2, tool_round=null, attempt_type='escalation' (provider B, fresh start)

`total_attempts` in `request.closed` counts escalation attempts only. Tool rounds are sub-attempts within one escalation attempt.

### 🟡 #15: OfficialRecordWriter.request_uuid vs v2 request_id

**Resolution: v2 uses `request_id` directly as the `uuid` column value.** No `stable_uuid` derivation. The `request_ref` column holds the same value. The old actors use `stable_uuid(request_ref)` which produces a different UUID — but they write to different rows because the v2 actor's ON CONFLICT uses `request_ref`, not `uuid`. Both coexist.

### 🟡 #16: response_writer polymorphic on operation

**Resolution: `insert_response` dispatches on `operation`.**

```ruby
def insert_response(payload)
  case payload[:operation]
  when 'embed'
    insert_embed_response(payload)
  else
    insert_chat_response(payload)
  end
end
```

`insert_embed_response` skips `response_content`, `finish_reason`, `tool_calls`. Sets `response_json = NULL`. Writes provider, model, tier, status, latency, error fields only.

### 🟢 #17-19: data_quality_flag NULL gap, TTFB capture, prefetch delay

- #17: Migration adds column with `default: 'legacy'` not NULL. All existing rows get 'legacy'. New rows get 'complete'. No NULL gap.
- #18: Implementation detail — `@timestamps[:first_token]` captured in the streaming block callback. Already available by stream completion.
- #19: Accepted. Eventual consistency window for status is documented. Not data-loss.
