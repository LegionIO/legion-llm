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

## Open Questions

1. Should `llm_policy_evaluations` be populated in Phase 2 (part of this work) or deferred to Phase 4?
2. Do we need a backfill job for the 57,779 existing `request_json = '{}'` rows, or accept that pre-fix data is lost?
3. Should the `llm.metering` exchange be formally deprecated in this release or left as-is?
