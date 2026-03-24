# Legion::LLM Routing Re-envisioned

> **Status: Superseded by unified integration design (2026-03-23). This document remains as conceptual foundation. Authoritative step reference is `docs/plans/2026-03-23-llm-unified-integration-design.md`**

## Status: Draft / Brainstorming

## Problem

The current LLM subsystem has sprawled across too many gems and communication paths:

- `legion-llm` does some routing and direct calls
- `lex-llm-gateway` does routing over AMQP
- `legion-mcp` has its own Tier 0 routing
- `legion-gaia` coordinates cognitive behavior separately
- Extensions-ai gems each handle their own provider logic
- Chat lives in both the LegionIO main gem and legion-tty

LLM requests can enter via at least 4 paths (direct, HTTP, AMQP, MCP) with no single authority controlling them. Routing logic is duplicated. Context management is fragmented.

## Goal

**`Legion::LLM` becomes the single authority for all LLM operations in the system.** It delegates execution to LEX extensions but owns all decision-making, state, routing, and context management. The same pattern as `Legion::GAIA` for cognitive coordination.

## Core Principles

1. **One entry point**: `Legion::LLM.chat()` -- every consumer (CLI, API, RMQ, interlink, LEX runners) calls the same method
2. **Conversation UUID**: every LLM interaction gets a UUID. One-shots included. Caller can provide one to resume a conversation
3. **Context is portable**: start in interlink, continue in CLI, switch providers mid-conversation. The UUID is the portability layer
4. **Gateway by default**: calling through `Legion::LLM.chat()` gives you the full pipeline (routing, context, RAG, RBAC, audit). Want raw access? Call the provider LEX directly
5. **No partial pipeline**: you're either using the gateway or you're not. No config flags for "half pipeline"

## What Changes

| Current | Fate |
|---------|------|
| `legion-llm` | Expands -- becomes the LLM authority |
| `lex-llm-gateway` | Absorbed into `legion-llm` |
| `extensions-ai/*` | Stay as LEX provider adapters, called by `legion-llm` |
| LLM routing in `legion-mcp` | Removed, calls `Legion::LLM.chat()` instead |
| Chat in LegionIO main gem | Thin client that calls `Legion::LLM.chat()` |
| Chat in legion-tty | Thin client that calls `Legion::LLM.chat()` |

## Single Entry Point

```ruby
module Legion
  module LLM
    def self.chat(messages:, conversation_id: nil, **opts)
      # UUID: have one? load it. Don't? Make one.
      conversation_id ||= SecureRandom.uuid
      context = ConversationStore.find_or_create(conversation_id)

      # RBAC check
      ACP.check!(context, opts)

      # Build smart context (RAG if history exists, raw if new)
      payload = ContextBuilder.build(context, messages, opts)

      # Route and call
      provider = Router.select(payload, opts)
      response = provider.chat(payload)

      # Store the delta
      ConversationStore.append(conversation_id, messages, response)

      # Always return the UUID
      { conversation_id: conversation_id, response: response }
    end
  end
end
```

Every consumer is just a thin wrapper:

```ruby
# API controller
post '/api/v1/llm/chat' do
  Legion::LLM.chat(**parsed_params)
end

# RMQ consumer
def handle(message)
  Legion::LLM.chat(**message.payload)
end

# LEX runner mid-task
result = Legion::LLM.chat(messages: [{ role: "user", content: "classify this" }])

# CLI chat
Legion::LLM.chat(messages: input, conversation_id: session_id)
```

## Conversation UUID

The UUID is the spine of the entire system. Everything hangs off it:

```
Conversation (UUID: abc-123)
├── Messages[]        # full history, ordered
├── Routing metadata  # current provider, escalation history
├── RBAC context      # who initiated, what policies apply
├── Audit trail       # every request/response, which provider, latency, tokens
└── State             # active, completed, escalated, denied
```

### UUID Behavior

- **No UUID provided**: auto-generate, create new conversation, return UUID in response
- **UUID provided, no history**: create new conversation with that UUID, proceed
- **UUID provided, has history**: load history, append new messages, continue

### Portability

The UUID enables seamless cross-interface continuity:

```bash
# Start in interlink, brainstorm for an hour
# Get conversation UUID: abc-123

# Continue in CLI with full context
$ legion chat --continue abc-123

# Import from external tools
$ legion chat --import claude-cli:<session-id>
```

Import/export adapters are LEX runners (lex-import-claude-cli, lex-import-openai, etc.).

## Context Management

### Two-Tier Cache

**Local cache** (in-memory + local Redis): personal conversations, fast, private. "I'm brainstorming about refactoring."

**Shared cache** (shared Redis or PG): team conversations, collaborative, RBAC-controlled. "The team discussed auth design, 6 people contributed." Conversations can be promoted from local to shared.

### Storage Architecture

```
Conversation Store (SQLite/PG via legion-data)
┌─────────────────────────────────┐
│ conversation_id │ seq │ message │   ← source of truth, append-only
└─────────────────────────────────┘
         │
         │ on write (async)
         ▼
Semantic Index (Apollo/pgvector)
┌──────────────────────────────────┐
│ conversation_id │ seq │ embedding │  ← RAG retrieval index
└──────────────────────────────────┘
```

- Every message stored in conversation store (source of truth) AND embedded into Apollo (search index)
- Hot layer: in-memory for active conversations, LRU eviction for cold ones
- Cold reads: load from DB on cache miss (e.g., resuming old conversation)
- Writes: append to in-memory + INSERT to DB (delta, never full rewrite)

### RAG-Based Context Building

Instead of sending entire conversation history to the LLM:

1. Take new message + last N recent messages
2. Embed current message, query semantic index for relevant historical messages
3. Assemble: system prompt + relevant history + recent messages + new message
4. If LLM needs more, it can use a `retrieve_context` tool to search conversation history

```ruby
# LLM has access to:
tools: [{
  name: "retrieve_context",
  description: "Search conversation history for relevant context",
  parameters: { query: "string" }
}]
```

This keeps context windows manageable, makes long conversations efficient, and enables the escalation scenario (switch providers without sending 2000 messages).

## Routing

### Funnel Model

The router is a funnel, not a waterfall. Start with everything, filter down, pick.

```
┌──────────────────────────────────┐
│  ALL CONFIGURED PROVIDERS        │  ollama, claude, openai, bedrock, gemini
└──────────────┬───────────────────┘
               ▼
┌──────────────────────────────────┐
│  1. PERMITTED (RBAC)             │  caller can't use gemini → remove
│     Pure policy lookup, cheapest │  → claude, openai, bedrock, ollama
│     check. Deny fast.            │
└──────────────┬───────────────────┘
               ▼
┌──────────────────────────────────┐
│  2. AVAILABLE (Health)           │  ollama is down → remove
│     Cached health state,         │  → claude, openai, bedrock
│     circuit breakers, heartbeats │
└──────────────┬───────────────────┘
               ▼
┌──────────────────────────────────┐
│  3. SELECT                       │  Explicit hint? Use it.
│     explicit → rules → smart     │  No hint? Rules match? Use it.
│     → default                    │  No rule? Analyze and pick.
│                                  │  → claude
└──────────────────────────────────┘
```

### Selection Strategies (Step 3)

Applied in order, first match wins:

1. **Explicit**: caller passed `model_hint` → use it if in pool, reject with reason if not
2. **Rules**: config-based mapping (task type, tool requirements, message patterns → provider)
3. **Smart**: analyze request (token estimate, tool complexity, conversation length) and pick best fit
4. **Default**: config default provider, last resort

### Escalation

Mid-conversation provider switching triggered by:

- **Router proactive**: conversation complexity exceeds local model capacity
- **Provider signal**: local model returns low-confidence or "I can't handle this"
- **User request**: "switch to a better model"
- **RBAC enforcement**: conversation now contains data above local model's classification

Escalation is recorded in conversation metadata:

```
conversation abc-123:
  exchanges 1-3: provider=ollama, model=llama3
  [escalation: complexity threshold, triggered by router]
  exchanges 4-N: provider=claude, model=opus
```

Context is handed off via RAG -- retrieve relevant history, send to new provider. Not the full blob.

### Fork

Send the same request to multiple providers simultaneously:

```ruby
Legion::LLM.chat(messages: [...], fork: [:claude, :openai])
# → { conversation_id: "abc", responses: [
#       { provider: :claude, response: { ... } },
#       { provider: :openai, response: { ... } }
#   ]}
```

Fork patterns:
- **Comparison**: return all answers, human picks
- **Consensus**: if they agree → use it, if they disagree → flag
- **Race**: first response wins, cancel the rest

## Full Request Pipeline (16 Steps)

Every step is explicit. No black boxes.

### Step 0: Tracing Init

```
Input:  request (may have tracing hash)
Action: tracing[:trace_id] ||= generate_trace_id
        tracing[:span_id] = generate_span_id
        propagate parent_span_id and baggage
Output: request with tracing populated
Fail:   can't fail (best-effort)
```

### Step 1: UUID Resolution

```
Input:  conversation_id (may be nil)
Action: conversation_id ||= SecureRandom.uuid
Output: guaranteed conversation_id
Fail:   can't fail
```

### Step 2: Caller Authentication

```
Input:  request.caller (requested_by + optional requested_for)
Action: resolve who is making this request
        → validate credential (JWT, API key, session, mTLS, internal)
        → resolve requested_by identity to roles/permissions
        → if requested_for present: validate delegation permission
Output: authenticated caller with identity + roles + delegation context
Fail:   401 - unknown/invalid caller → reject immediately
        403 - delegation not permitted → reject
```

### Step 3: RBAC Permission Check + Classification Filter

```
Input:  caller object + request.classification + request.billing
Action: "Is this caller allowed to use Legion::LLM at all?"
         Also produces the set of permitted providers.
         If classification.level is :restricted → remove all cloud providers.
         If classification.contains_phi → remove non-HIPAA-compliant providers.
         If classification.jurisdictions → remove providers outside jurisdictions.
         If billing.spending_cap or budget_id → estimate cost, reject if over budget.
Output: yes/no + permitted provider list (classification + RBAC filtered)
Fail:   403 - caller denied LLM access → reject, audit the denial
         403 - classification restriction violates all available providers → reject
         402 - budget exceeded → reject with budget_exceeded error
```

### Step 4: Provider Availability Filter

```
Input:  permitted providers (from step 3)
Action: check cached health state for each permitted provider
        (heartbeat, circuit breaker state, last-known status)
Output: available provider pool (permitted AND online)
Fail:   503 - no available providers → reject
```

### Step 5: Context Load

```
Input:  conversation_id
Action: ConversationStore.find(conversation_id)
        → exists? load message history + metadata
        → doesn't exist? create empty conversation record
Output: conversation object (may be empty, may have 400 messages)
Fail:   500 - store unreachable → reject (can't guarantee persistence)
```

### Step 6: Provider Selection

```
Input:  available pool (step 4) + conversation (step 5) + opts
Action: layered selection from the available pool:
        6a. EXPLICIT - caller passed model_hint?
            → find matching provider in pool
            → not in pool? reject with reason
        6b. RULES - config-based routing
            → match on: task type, message patterns, tool requirements
        6c. SMART - analyze request
            → token estimate, tool complexity, conversation length
            → pick best fit from pool
        6d. DEFAULT - config default provider
        Record predictions:
            → { source: :router, type: :provider_fit, expected: :ollama }
            → { source: :router, type: :tool_usage,   expected: true }
            → { source: :context, type: :token_estimate, expected: 1200 }
        If modality declared, check provider capabilities:
            → filter out providers that can't handle requested input/output modalities
Output: selected provider (or multiple if fork requested) + predictions
Fail:   500 - no selection possible

FORK: if opts[:fork], select N providers, steps 7-11 execute
      in parallel for each
```

### Step 7: Context Build (RAG)

```
Input:  conversation history (step 5) + new messages + selected
        provider's context window limit
Action:
  7a. Short conversation (fits in window): use full history
  7b. Long conversation:
      → always include: system prompt + last N recent messages
      → embed current message, query semantic index (Apollo)
      → retrieve top-K relevant historical messages
      → assemble: system + relevant + recent + new
      → verify total tokens fit provider's window
  7c. Attach tools if requested
  7d. Attach provider-specific config (temperature, etc.)
Output: assembled payload
Fail:   semantic index unreachable → degrade to "last N messages"
        truncation (functional but lower quality)
```

### Step 8: Request Normalization

```
Input:  assembled payload + selected provider
Action: translate from Legion internal format to provider's API format
        → message role mapping
        → tool/function format translation
        → image/attachment encoding
        → streaming config
Output: provider-native request
Fail:   400 - payload can't be translated (e.g., tools not supported
        by provider) → reject with reason
```

### Step 9: Provider Call

```
Input:  provider-native request
Action: Generate exchange_id for this hop (exch_{ulid})
        HTTP/SDK call to the LLM provider
        → streaming: open SSE/websocket, yield chunks
        → non-streaming: wait for complete response
        → timeout handling
        → retry logic (idempotent requests only, new exchange_id per attempt)
        → wire capture (if enabled, keyed by exchange_id)
Output: provider-native response + exchange_id
Fail:   502 - provider error → circuit breaker update
        → retries exhausted: attempt FAILOVER
        → re-enter step 6 with failed provider removed from pool
        → no providers left: 503 to caller
        Each failed attempt records exchange_id in retry.history
```

### Step 10: Response Normalization

```
Input:  provider-native response
Action: translate back to Legion internal format
        → unified message structure
        → tool call extraction
        → token usage stats
        → finish reason
Output: normalized response object
Fail:   500 - malformed provider response → log, return error
```

### Step 11: Tool Call Handling (Agentic Loop)

```
Input:  normalized response
Action: does response contain tool calls?
  → NO:  proceed to step 12
  → YES: for each tool call:
         → resolve tool (LEX runner, MCP tool, built-in)
         → RBAC check: is caller permitted to use this tool?
         → execute tool
         → collect results
         → append tool calls + results to conversation
         → LOOP BACK TO STEP 7 with updated context
         → loop limit check (max_iterations, configurable)
Output: final response (no more tool calls)
Fail:   tool execution failure → include error in tool result,
        let LLM decide how to handle
        loop limit exceeded → return partial with warning
```

### Step 12: Context Store (Persist)

```
Input:  conversation_id + new messages + response
Action:
  12a. Append all new messages to ConversationStore (INSERT, delta only)
  12b. Update conversation metadata (provider, token counts, timestamps)
  12c. Update local cache (hot layer)
  12d. If conversation is shared: update shared cache
Output: updated conversation record
Fail:   TBD - hard fail or degraded mode? (design decision)
```

### Step 13: Semantic Index Update

```
Input:  new messages
Action: embed new messages, write to Apollo/pgvector
        → ASYNC (don't block the response)
        → queue for background processing
Output: (async, no output to caller)
Fail:   index write failure → log, degrade gracefully
        (RAG quality drops but system still works)
```

### Step 14: Audit Log

```
Input:  everything — caller, conversation_id, provider, token usage,
        latency, routing decision reason, escalation events, tool calls
Action: write audit record
        → ties to conversation UUID
        → immutable append-only log
Output: (async, no output to caller)
Fail:   TBD - reject request if audit fails? (compliance decision)
```

### Step 15: Prediction Resolution

```
Input:  predictions from step 6 + actual response data
Action: compare each prediction to reality:
        → tool_usage predicted true, actual true → correct
        → provider_fit predicted ollama, actual claude → incorrect (escalated)
        → token_estimate predicted 1200, actual 1245 → correct, variance 0.037
        Fill in actual, correct, variance, reason on each Prediction struct.
Output: resolved predictions array
Fail:   can't fail (best-effort)
```

### Step 16: Response Return

```
Input:  normalized response + conversation_id + resolved predictions + tracing
Output: Response struct (see schema spec) with all fields populated:
        conversation_id, message, routing (with connection), tokens
        (with utilization), thinking, stop, tools, stream, cache, retry,
        timestamps, cost, quality, validation, safety, rate_limit,
        features, deprecation, enrichments, audit, predictions, timeline,
        participants, tracing, caller, classification, agent, billing,
        test, warnings, wire
```

## Resolved Design Decisions

### Step 12: Persistence Failure

Not a hard fail. Not degraded mode. **Spool it.**

If the direct DB write fails, the messages go to `Legion::Data::Spool` (local buffer, survives restarts). A background worker drains the spool to the DB when it's available again. The response always goes back to the caller.

```
Step 12: Context Store
  Try:  direct write to ConversationStore (SQLite/PG)
  Fail: → Legion::Data::Spool (local buffer, durable)
        → background worker drains to DB when available
  Either way: response returns to caller
```

### Step 14: Audit Failure

Audit always goes through `Legion::Transport` (RMQ). It should never be a local DB write -- audit needs to go to a central place for aggregation, compliance, and cross-node search. A dedicated consumer persists it wherever the organization needs it.

If RMQ publish fails, same pattern: spool it.

Configurable hard-deny for compliance-heavy environments:

```
llm.rbac.audit.deny_on_failed_audit_write: false  # default permissive
```

```
Step 14: Audit Log
  Always: → Legion::Transport (RMQ) → central audit consumer
  Fail:   → Legion::Data::Spool → retry on reconnect
  Config: deny_on_failed_audit_write: true → reject request if audit can't be written
```

### LLM API Reality: All Providers Are Stateless

Every major LLM API is stateless. There is no server-side session. Every request is a one-shot. You send the full message array every time.

- **Anthropic (Claude)**: stateless, full messages array every call
- **OpenAI (GPT)**: stateless, full messages array every call
- **AWS Bedrock**: stateless, full payload every call
- **Ollama**: stateless, full messages array
- **Google Gemini**: stateless (has experimental context caching, but base API is stateless)

Tools like Claude Code send the entire conversation history with every single API call. They compress/summarize older context as they approach window limits because they have to.

This is exactly why Legion::LLM's architecture matters: centralized context management with RAG-based smart retrieval instead of sending the full blob or doing lossy compression.

## Open Design Decisions

1. **Boot order**: where does the expanded `legion-llm` sit in the boot sequence?
2. **Streaming**: how do streaming responses interact with the context store and audit? Store on completion? Store chunks?
3. **Fork storage**: does a forked response store all provider responses, or just the "winner"?

## Component Map

```
legion-llm (THE authority)
├── ConversationStore   # CRUD for conversations by UUID
├── ContextBuilder      # Assembles LLM payload (RAG, truncation, tools)
├── Router              # Funnel: RBAC → Available → Select
├── ProviderRegistry    # Tracks configured providers + health state
├── ACP/RBAC Gate       # Permission checks + audit logging
│
├── Delegates to LEX for execution:
│   ├── lex-azure-ai    # provider adapter
│   ├── lex-bedrock     # provider adapter
│   ├── lex-claude      # provider adapter
│   ├── lex-openai      # provider adapter
│   ├── lex-ollama      # provider adapter
│   ├── lex-gemini      # provider adapter
│   ├── lex-xai         # provider adapter
│   ├── lex-apollo      # RAG retrieval (semantic index)
│   └── lex-import-*    # conversation import adapters
│
└── Exposes:
    ├── Legion::LLM.chat(...)         # single entry point
    ├── Legion::LLM.context(uuid)     # retrieve conversation
    └── Legion::LLM.providers         # list available providers
```

## Schema Specification

See [llm-schema-spec.md](llm-schema-spec.md) for the complete request/response schema, including:
- Message format with ID, parent_id, status, version
- Content block types (text, thinking, image, audio, video, document, file, tool_use, tool_result, citation, error)
- Tool definitions with source attribution
- Symmetric request/response keys (routing, tokens, stop, tools, stream, enrichments, predictions) -- all hash-keyed by `"source:type"` for direct lookup
- Audit trail (hash-keyed, response-only, separate from enrichments -- decisions and outcomes, not request-shaping)
- Enrichment system (generic, any source can contribute)
- Prediction/hypothesis testing (before/after comparison, self-improvement loop)
- OpenTelemetry-compatible tracing & correlation
- Caller identity (requested_by / requested_for -- auth principals, workload identity, delegation)
- Data classification & compliance (PII/PHI, jurisdictions, retention -- upgrade-only, never downgrade)
- Agent identity & delegation chains (AI entity tracking, separate from caller auth)
- Billing & budget enforcement
- Test & evaluation modes (mock, record, replay, shadow, A/B experiments)
- Modality declarations (input/output capability routing)
- Retry tracking (distinct from escalation, with attempt history)
- Content safety (provider filtering results -- hate, violence, etc.)
- Rate limit state (structured provider quota from response headers)
- Thinking & reasoning controls (extended thinking, reasoning effort, budget)
- Context window utilization (utilization ratio, headroom)
- Structured output validation (JSON schema validation results, auto-repair)
- Provider features used (prompt caching, search grounding, batch mode, etc.)
- Model deprecation warnings (structured, actionable by automation)
- Pipeline timeline (Homer-style globally-sequenced call flow reconstruction)
- Participants registry (all systems that touched the request)
- Wire capture (raw request + response payloads, opt-in, for translator debugging)
- Connection context (pool, reuse, TLS, endpoint per provider call)
- Lifecycle hooks (caller-declared pipeline injection points)
- Feedback loop (user and automated quality feedback)
- Streaming chunks
- Error response format
- Provider adapter contract & translator pattern
- Schema versioning
- Exchange (per-hop tracking) -- three-level ID hierarchy: conversation_id (session), request.id (turn), exchange_id (hop/leg)
- Full JSON examples with complete timeline (including exchange_id per hop)

## Phase 0 Build Scope

The minimum to prove the architecture:

1. `Legion::LLM.chat()` entry point with UUID handling
2. ConversationStore (SQLite via legion-data, one row per message)
3. Router with explicit + default strategies only (rules and smart come later)
4. One provider adapter (Ollama or OpenAI as simplest)
5. Request/response normalization structs
6. Basic audit logging (write to conversation metadata)

RAG, fork, escalation, shared cache, import/export -- all layer on after phase 0 proves the single-path architecture works.

## GAIA Relationship

### Roles

- **Legion::LLM** is the builder. Capable of executing any LLM operation.
- **Legion::GAIA** is the 30-year veteran. Quiet, observing, and when you ask her, she gives you answers that bypass hours/months of work.

GAIA doesn't build. She **knows**. Legion::LLM doesn't know. It **executes**.

### Dependency Rule

**legion-llm never requires GAIA. GAIA requires legion-llm.** If GAIA is down, LLM works. If LLM is down, GAIA can't do much.

However, legion-llm CAN consult GAIA when she's available. The advisory path is lightweight (cached knowledge, not LLM calls). No circular dependency because:

- `legion-llm → GAIA`: "advise me" (sync, in-memory lookup, GAIA does NOT call Legion::LLM.chat during advisory)
- `GAIA → legion-llm`: "I need an LLM call" (normal request through the pipeline, legion-llm skips GAIA advisory hooks to prevent recursion)

### Three Touchpoints

| When | What | How |
|------|------|-----|
| **Before** (step 0) | Shape the request | Enrich prompt, pre-select provider, add cross-conversation context, set guardrails |
| **During** (steps 6, 7, 11) | Advise in real-time | Adjust routing, enrich context, flag risky tool calls |
| **After** (post step 14) | Observe and learn | Process outcome via RMQ, update knowledge store, find patterns |

### GAIA as Observer

GAIA's async observation is just another RMQ consumer. Every conversation event that legion-llm publishes (step 14 audit), GAIA has her own consumer reading the same stream. No special hooks -- she subscribes and processes on her own schedule.

```
legion-llm step 14:
  → publish to audit exchange on RMQ

Consumers:
  ├── audit-consumer    → writes to central audit store
  └── gaia-observer     → GAIA processes, learns, surfaces insights
```

Even simple operations (bump a version.rb) flow through GAIA's observer. She may not act in real-time, but she processes it async: "why did they need to bump manually? should this be automated?" Over time, she learns to preempt repetitive work.

### Agentic Extensions as GAIA's Senses

The extensions-agentic gems are not GAIA's limbs -- they're her **senses**. Each cognitive domain extension is a lens through which she observes and categorizes what's happening. They feed structured observations to her knowledge store.

GAIA's internal architecture (how senses feed knowledge, push vs pull, knowledge accumulation) is a separate design topic.

### GAIA's Knowledge Architecture

```
GAIA
├── Observation Layer
│   └── Consumes ALL events from RMQ
│       → every conversation, tool call, routing decision,
│         escalation, failure, success
│       → async, never in the critical path
│
├── Knowledge Store
│   └── Accumulated patterns, not raw events
│       → "provider X fails on task type Y 73% of the time"
│       → "user A always needs Z after asking about Y"
│       → "this error pattern means the config is wrong"
│       → "conversation xyz-789 solved this same problem"
│       → Apollo/pgvector for semantic search
│
└── Advisory Interface
    └── Sync, fast, in-memory / cached lookups
        → Legion::GAIA.advise(context) → recommendation
        → no LLM calls, no heavy computation
        → she already knows, she just tells you
```

## Provider Adapter Contract

### The Standard Interface

Every provider LEX must implement `Legion::LLM::ProviderAdapter`. Same methods, same data shapes, same error types. Internals can differ (each API is different) but the outside is identical.

```ruby
module Legion
  module LLM
    module ProviderAdapter
      # ═══════════════════════════════════════════
      # REQUIRED - every provider MUST implement
      # ═══════════════════════════════════════════

      # Standard chat completion
      def chat(request)
        raise NotImplementedError
      end

      # Streaming chat - yields chunks, returns full response
      def chat_stream(request, &block)
        raise NotImplementedError
      end

      # What can this provider do?
      def capabilities
        # { streaming: true, tools: true, vision: true,
        #   embedding: false, max_context_tokens: 200_000,
        #   max_output_tokens: 8_192,
        #   models: ["claude-opus-4-6", "claude-sonnet-4-6"],
        #   formats: [:json, :text, :markdown] }
        raise NotImplementedError
      end

      # Is this provider alive?
      def health_check
        # { status: :healthy, latency_ms: 45 }
        # { status: :degraded, reason: "high latency" }
        # { status: :down, reason: "connection refused" }
        raise NotImplementedError
      end

      # Estimate token count for a payload
      def token_estimate(messages)
        raise NotImplementedError
      end

      # ═══════════════════════════════════════════
      # OPTIONAL - implement if provider supports it
      # ═══════════════════════════════════════════

      def embed(text)
        raise Legion::LLM::UnsupportedCapability, :embedding
      end

      def summarize(content, opts = {})
        raise Legion::LLM::UnsupportedCapability, :summarization
      end
    end
  end
end
```

### Standard Client Pattern

Providers are **connection pools**, not per-request objects. Initialized once at boot, shared across all requests.

```ruby
# Provider lifecycle
Provider instance: long-lived (boot to shutdown)
  → holds: HTTP client, connection pool, auth, config

Request object: per-call, ephemeral
  → holds: messages, tools, model, params

Conversation: persistent, outlives everything
  → lives in ConversationStore, not in the provider
```

```ruby
# ProviderRegistry holds one instance per configured provider
Legion::LLM::ProviderRegistry
  ├── :claude  → Lex::Claude::Provider (pool_size: 10)
  ├── :ollama  → Lex::Ollama::Provider (pool_size: 5)
  ├── :bedrock → Lex::Bedrock::Provider (pool_size: 10)
  └── :openai  → Lex::OpenAI::Provider (pool_size: 10)
```

### Standard Error Contract

Providers MUST raise Legion::LLM errors, never their own. This lets legion-llm handle all errors uniformly:

```
Legion::LLM::AuthError              → don't retry, fix credentials
Legion::LLM::RateLimitError         → retry with backoff
Legion::LLM::ContextOverflow        → reduce context, retry
Legion::LLM::ProviderError          → transient, retry
Legion::LLM::ProviderDown           → circuit breaker, failover
Legion::LLM::UnsupportedCapability  → route elsewhere
```

### Example Provider Implementation

```ruby
module Lex
  module Claude
    class Provider
      include Legion::LLM::ProviderAdapter

      def initialize(config)
        @client = Anthropic::Client.new(api_key: config[:api_key])
      end

      def chat(request)
        raw = @client.messages.create(
          model: request.model,
          messages: translate_messages(request.messages),
          tools: translate_tools(request.tools)
        )
        normalize_response(raw)
      rescue Anthropic::AuthError => e
        raise Legion::LLM::AuthError, e.message
      rescue Anthropic::RateLimitError => e
        raise Legion::LLM::RateLimitError, e.message
      end

      def capabilities
        { streaming: true, tools: true, vision: true,
          embedding: false, max_context_tokens: 200_000,
          models: ["claude-opus-4-6", "claude-sonnet-4-6"] }
      end

      # ... health_check, token_estimate, chat_stream ...

      private

      # All provider-specific translation is private
      def translate_messages(messages) = # ...
      def normalize_response(raw) = # ...
    end
  end
end
```

From legion-llm's side, every provider looks identical:

```ruby
provider = Legion::LLM::ProviderRegistry.get(:claude)
provider.chat(request)       # same call regardless of provider
provider.capabilities        # same shape
provider.health_check        # same shape
```
