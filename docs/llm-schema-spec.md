# Legion::LLM Schema Specification

## Status: Draft / Brainstorming

## Design Principles

1. **Symmetry**: shared keys between request and response use the same name and comparable structure. If both sides have token data, both use `:tokens`. Compare by diffing, not by mapping.
2. **Flat over nested**: if a field is always present, make it first-class. Don't bury required data in hashes. Use hashes for logical groups, not for hiding structure.
3. **Generic over specific**: don't couple the schema to specific systems (GAIA, MCP). Use extensible patterns (enrichments array) so any system can participate without schema changes.
4. **Nothing is lost**: every feature every provider supports has a place in the schema. Content blocks, tool calls, multimodal, reasoning traces, citations -- all representable.
5. **Sequel-thorough**: like the Sequel gem is to databases, this schema is to LLM providers. One unified format, every edge case handled, provider adapters translate at the edges.
6. **RFC-grade**: designed to be THE standard, not just our internal format. Version-stamped, extensible, forward-compatible.

## Schema Version

Every request, response, and error includes a schema version:

```
schema_version: "1.0.0"   # semver -- major.minor.patch
```

- **Major**: breaking changes (field removed, type changed)
- **Minor**: new optional fields added
- **Patch**: documentation/clarification only

---

## Message

The atomic unit of conversation. Every exchange between user, assistant, and tools is a Message.

```
Message
  id:                String       # unique, auto-generated ("msg_abc123")
  parent_id:         String?      # what message this is in response to
  role:              Symbol       # :user, :assistant, :tool
  content:           String | Array<ContentBlock>
  tool_calls:        Array<ToolCall>?   # on assistant messages (parallel batch)
  tool_call_id:      String?      # on tool result messages
  name:              String?      # tool name for tool results
  status:            Symbol       # :created, :regenerated, :edited, :redacted
  version:           Integer      # 1, 2, 3... (increments on regeneration)
  timestamp:         Time
  seq:               Integer      # position in conversation
  provider:          Symbol?      # which provider generated this
  model:             String?      # which model generated this
  input_tokens:      Integer?     # tokens this message consumed
  output_tokens:     Integer?     # tokens this message generated
```

### Message.id

Every message gets a unique ID. Not just tool calls. Required for:
- RAG retrieval ("retrieve message msg_abc123")
- Conversation forking (branch at a specific message)
- Audit trails (which messages were sent to the provider)
- Cross-conversation references ("see msg_xyz in conversation abc-123")

### Message.parent_id

In a linear conversation, parent_id is the previous message's ID. In forked conversations or multi-turn tool call loops, it tracks the actual reply chain. Enables tree-structured conversations.

### Message.status

- `:created` -- normal, generated or received
- `:regenerated` -- user asked for a new response (version increments)
- `:edited` -- user modified the content after generation
- `:redacted` -- content removed (PII, compliance). RAG should not retrieve redacted messages.

### Convenience methods

```ruby
message.text  # returns text content regardless of String vs Array<ContentBlock>
              # extracts and joins all :text blocks if content is an array
```

---

## Content Blocks

Multimodal content. When `Message.content` is an array, each element is a ContentBlock.

### Block Types

```
:text           Plain text content
:thinking       Reasoning trace (Claude extended thinking, chain-of-thought)
:image          Image data (base64 or URL)
:audio          Audio data (base64 or URL)
:video          Video data (base64 or URL)
:document       Inline document (PDF, DOCX)
:file           Reference to uploaded/stored file
:tool_use       Tool invocation (on assistant messages)
:tool_result    Tool response (on user messages)
:citation       Source attribution
:error          Structured error content
```

### TextBlock

```
type:            :text
text:            String
cache_control:   Hash?        # Anthropic prompt caching: { type: "ephemeral" }
```

### ThinkingBlock

```
type:            :thinking
text:            String        # reasoning trace content
```

### ImageBlock

```
type:            :image
source_type:     Symbol        # :base64, :url
media_type:      String        # "image/png", "image/jpeg", "image/gif", "image/webp"
data:            String        # base64 data or URL
detail:          Symbol?       # :high, :low, :auto (OpenAI vision detail level)
```

### AudioBlock

```
type:            :audio
source_type:     Symbol        # :base64, :url
media_type:      String        # "audio/mp3", "audio/wav", "audio/ogg"
data:            String
```

### VideoBlock

```
type:            :video
source_type:     Symbol        # :base64, :url
media_type:      String        # "video/mp4", "video/webm"
data:            String
```

### DocumentBlock

```
type:            :document
source_type:     Symbol        # :base64, :url
media_type:      String        # "application/pdf", etc.
data:            String
name:            String?       # filename
```

### FileBlock

```
type:            :file
file_id:         String        # provider or internal file reference
media_type:      String
name:            String?
```

### ToolUseBlock

```
type:            :tool_use
id:              String        # tool call ID
name:            String        # tool name
input:           Hash          # tool arguments
```

### ToolResultBlock

```
type:            :tool_result
tool_use_id:     String        # matches ToolUseBlock.id
content:         String | Array<ContentBlock>
is_error:        Boolean?
```

### CitationBlock

```
type:            :citation
source:          String        # source identifier (URL, document name, message ID)
text:            String?       # cited text
start_index:     Integer?      # character position in parent text
end_index:       Integer?
```

### ErrorBlock

```
type:            :error
code:            Symbol        # error type
message:         String        # human-readable error
data:            Hash?         # structured error data
```

---

## Tool

Tool definitions available to the LLM.

```
Tool
  name:            String
  description:     String
  parameters:      Hash          # JSON Schema for input
  source:          Hash          # where this tool came from
  version:         String?       # tool schema version
```

### Tool.source

Every tool tracks its origin:

```
{ type: :mcp,     server: "filesystem" }
{ type: :lex,     extension: "lex-github" }
{ type: :builtin, name: "retrieve_context" }
{ type: :gaia,    reason: "injected for this request" }
```

Used by RBAC (can this caller use tools from this source?) and audit (which systems contributed tools?).

---

## ToolCall

A tool invocation made by the assistant, with execution results.

```
ToolCall
  id:              String        # unique call ID
  exchange_id:     String?       # which exchange triggered this tool call
                                 # links to the provider exchange that requested it
  name:            String        # tool name
  arguments:       Hash          # parsed arguments (NOT a JSON string, always a Hash)
  source:          Hash          # echoed from Tool.source
  status:          Symbol        # :success, :error, :timeout, :denied
  duration_ms:     Integer?      # execution time
  result:          String | Array<ContentBlock>?   # tool output
  error:           String?       # error message if status is :error
```

### ToolCall.arguments

Always a parsed Hash, never a JSON string. Provider adapters that receive arguments as JSON strings (OpenAI) MUST parse them in the translator. Consumers should never need to call `JSON.parse` on tool arguments.

---

## ToolChoice

Controls how the LLM uses available tools.

```
ToolChoice
  mode:            Symbol        # :auto, :required, :none, :specific
  name:            String?       # tool name when mode is :specific
```

---

## Enrichment

Things that *shaped* the request during processing. Any system can contribute enrichments without schema changes. Enrichments modify or observe the request -- for decisions and outcomes, see [Audit](#audit).

Enrichments are a **Hash keyed by `"source:type"`**, not an array. This enables direct lookup and clean request-vs-response comparison without looping.

```
enrichments:       Hash<String, Enrichment>

# Key format: "source:type"
# Value:
Enrichment
  content:         String        # human-readable description
  data:            Hash?         # structured data if needed
  duration_ms:     Integer       # how long this enrichment took
  timestamp:       Time
```

### Why hash keys, not arrays

Arrays require looping to compare request vs response:
```ruby
# Bad: array looping
req_rag = request.enrichments.find { |e| e[:source] == :rag && e[:type] == :context_retrieval }
resp_rag = response.enrichments.find { |e| e[:source] == :rag && e[:type] == :context_retrieval }
```

Hash keys enable direct lookup:
```ruby
# Good: direct access
request.enrichments[:"gaia:system_prompt"]
response.enrichments[:"rag:context_retrieval"]

# Diff what was added between request and response
response.enrichments.keys - request.enrichments.keys
```

### Example

```ruby
request.enrichments = {
  "gaia:system_prompt":    { content: "user prefers small changes", duration_ms: 22,
                             timestamp: Time.now },
  "rag:context_retrieval": { content: "15 of 400 messages selected", duration_ms: 120,
                             timestamp: Time.now },
  "mcp:tool_registration": { content: "8 tools from 2 servers", duration_ms: 1500,
                             timestamp: Time.now }
}
```

Filter by source: `enrichments.select { |k, _| k.start_with?("gaia:") }`

Adding a new system requires zero schema changes -- just add a new key.

---

## Prediction

Hypothesis recorded before execution, compared to reality after execution. Enables self-improving systems. Any component in the pipeline can contribute predictions.

Predictions are a **Hash keyed by `"source:type"`**, same pattern as enrichments. Direct lookup, no looping.

```
predictions:       Hash<String, Prediction>

# Key format: "source:type"
# Value:
Prediction
  expected:        Any          # the prediction (boolean, symbol, integer, string)
  confidence:      Float?       # 0.0 to 1.0 -- how sure the predictor is
  basis:           String?      # why this prediction was made

  # Response-side only (filled after execution)
  actual:          Any?         # what actually happened
  correct:         Boolean?     # did prediction match reality?
  variance:        Float?       # for numeric predictions (how far off)
  reason:          String?      # explanation when incorrect
```

### How predictions work

Request side -- before execution:
```ruby
predictions = {
  "router:tool_usage":    { expected: true,    confidence: 0.8,
                            basis: "message contains 'what files'" },
  "router:provider_fit":  { expected: "ollama", confidence: 0.6,
                            basis: "low complexity estimate" },
  "gaia:complexity":      { expected: "low",   confidence: 0.7,
                            basis: "similar to previous 12 requests" },
  "context:token_estimate": { expected: 1200,  confidence: 0.9,
                              basis: "15 messages, avg 80 tokens each" }
}
```

Response side -- after execution:
```ruby
predictions = {
  "router:tool_usage":    { expected: true,    actual: true,    correct: true },
  "router:provider_fit":  { expected: "ollama", actual: "claude", correct: false,
                            reason: "escalated at exchange 3, nested tool calls too complex" },
  "gaia:complexity":      { expected: "low",   actual: "high",  correct: false,
                            reason: "required 3 tool calls and 2 follow-ups" },
  "context:token_estimate": { expected: 1200,  actual: 1245,    correct: true, variance: 0.037 }
}
```

### Direct comparison

```ruby
# Was the tool usage prediction correct?
response.predictions[:"router:tool_usage"][:correct]  # => true

# How far off was the token estimate?
response.predictions[:"context:token_estimate"][:variance]  # => 0.037

# What % of predictions were correct?
response.predictions.count { |_, v| v[:correct] }.to_f / response.predictions.size
```

### What predictions enable

**Router improvement**: "Last 50 requests with MCP filesystem tools: Ollama predicted sufficient 50 times, actually sufficient 31 times (62%). Adjust confidence downward."

**GAIA learning**: "Last 100 complexity predictions: predicted low + was actually high = 14 misses, all involved code refactoring. Learn: code refactoring is never low complexity."

**Cost optimization**: "Predicted 1200 tokens, got 4800. Pattern: architecture questions consistently underestimated by 4x."

**A/B testing**: fork the same request with/without GAIA context, compare prediction accuracy and response quality across variants.

---

## Tracing & Correlation

OpenTelemetry-compatible distributed tracing. Groups related requests across agentic loops, forks, and multi-step tasks.

```
tracing:           Hash
  trace_id:        String       # OpenTelemetry trace -- groups all requests from
                                # one user action (e.g., "refactor auth" triggers
                                # 5 LLM calls, all share one trace_id)
  span_id:         String       # this specific request within the trace
  parent_span_id:  String?      # the request that spawned this one
                                # (agentic loop iteration 2 -> iteration 1)
  correlation_id:  String?      # business-level grouping
                                # ("all requests for ticket PROJ-1234")
  baggage:         Hash?        # propagated context that flows through the pipeline
```

### Why this matters

Without tracing, you can't answer:
- "Show me every LLM call that happened when the user said 'refactor auth'"
- "How many total tokens did this agentic loop consume across all iterations?"
- "Which step in the tool call chain caused the escalation?"
- "What's the end-to-end latency from user input to final response?"

Tracing is present on Request, Response, ErrorResponse, and Chunk.

---

## Exchange (Per-Hop Tracking)

Three-level ID hierarchy inspired by SIP's Call-ID / CSeq / Branch/Via model. Tracks every hop within a single request.

```
conversation_id    # session    (SIP Call-ID)
                   # Groups all requests in a conversation. Persists across turns.
                   # "The whole phone call."

request.id         # turn       (SIP INVITE/CSeq)
                   # One user message → one request ID. Groups all processing for that turn.
                   # "One question-answer pair."

exchange_id        # hop/leg    (SIP Branch/Via)
                   # One provider call, one tool execution, one retry attempt.
                   # "One wire round-trip."
```

### Why three levels

Without `exchange_id`, you can see that a request succeeded but not *which attempt* succeeded or *which provider call* hit a tool. Consider:

```
request req_abc123:
  exchange exch_001 → ollama → 500 (failed, retry)
  exchange exch_002 → ollama → 500 (failed, escalate)
  exchange exch_003 → claude → 200 (tool_use: list_files)
    exchange exch_004 → tool:list_files → success
  exchange exch_005 → claude → 200 (end_turn, success)
```

Each exchange gets its own wire capture, its own timeline events, and its own duration. The request ID groups them; the exchange ID identifies the individual leg.

### Where exchange_id appears

| Struct | Purpose |
|--------|---------|
| `TimelineEvent.exchange_id` | Groups timeline events into legs |
| `ToolCall.exchange_id` | Which provider exchange triggered this tool call |
| `Chunk.exchange_id` | Which exchange is streaming |
| `wire` (keyed by exchange_id) | One wire capture per exchange, not per request |
| `retry.history[].exchange_id` | Each failed attempt references its exchange |

### Exchange ID format

```
exch_{ulid}   # e.g., "exch_01HZ3G4K7P0000000000000001"
```

Auto-generated by the pipeline at the start of each provider call, tool execution, or retry attempt. Callers never set this.

### Relationship to tracing

Exchange IDs are **internal to Legion**. They track hops within a single request's pipeline execution. Tracing (trace_id, span_id) is **external/cross-system** OpenTelemetry context. They're complementary:

- `trace_id` → "all LLM calls from the user's refactoring task"
- `request.id` → "this specific LLM turn"
- `exchange_id` → "this specific provider call within that turn"

In practice, each exchange would become a child span under the request's span in OpenTelemetry, but exchange_id exists even without OTel configured.

---

## Data Classification & Compliance

Data governance for enterprise adoption. Controls where data can be processed, how long it's retained, and what it contains.

```
classification:    Hash?
  level:           Symbol       # :public, :internal, :confidential, :restricted
  contains_pii:    Boolean      # personally identifiable information
  contains_phi:    Boolean      # protected health information (HIPAA)
  jurisdictions:   Array<String>  # where data can be processed: ["us"], ["us", "eu"], ["*"]
  retention:       Symbol       # :default, :session_only, :days_30, :days_90, :permanent
  consent:         Hash?        # user consent record
    granted:       Boolean
    scope:         String       # what was consented to
    timestamp:     Time
```

### Classification levels

- `:public` -- no restrictions, can go to any provider
- `:internal` -- can go to cloud providers with data processing agreements
- `:confidential` -- restricted to approved providers, may exclude certain clouds
- `:restricted` -- on-premise only, never leaves the network (Ollama, local fleet)

### How classification affects routing

Classification feeds into the routing funnel at step 1 (RBAC/Permission). It's not who-can-use-what (that's RBAC), it's what-data-can-go-where:

```
Request has classification.level = :restricted
  → Router removes ALL cloud providers from the pool
  → Only local Ollama and fleet providers remain
  → If none are available: reject with reason, don't silently send to cloud

Request has classification.contains_phi = true
  → Router removes providers not in PHI-approved list
  → Audit enrichment: "PHI detected, restricted to HIPAA-compliant providers"
```

### Jurisdiction

```
jurisdictions: ["us"]          # US processing only
jurisdictions: ["us", "eu"]    # US or EU processing
jurisdictions: ["*"]           # no geographic restriction
```

Provider registry includes each provider's processing jurisdiction. Router matches request jurisdiction to provider jurisdiction.

---

## Caller

Auth-level identity tracking. Who authenticated to make this request, and on whose behalf. Separate from `agent` (which tracks AI entity identity).

```
caller:            Hash?
  requested_by:    Hash              # the authenticated principal
    identity:      String            # "user:matt", "gh:LegionIO/legion/ci",
                                     # "service:call-center-bot"
    type:          Symbol            # :user, :service, :workload, :bot
    credential:    Symbol            # :jwt, :api_key, :session, :mtls, :internal
    name:          String?           # human-readable name

  requested_for:   Hash?             # on whose behalf (nil if same as requested_by)
    identity:      String            # "customer:12345", "team:platform"
    type:          Symbol            # :user, :customer, :team, :org
    name:          String?
    relationship:  String?           # why this delegation exists
```

### Caller vs Agent

These are orthogonal:
- **Caller** = who authenticated and who benefits (auth layer)
- **Agent** = which AI entity is doing the work (execution layer)

Both, neither, or either can be present:

```
# Terminal user, no AI agent
caller: { requested_by: { identity: "user:matt", type: :user, credential: :session } }
agent: nil

# GitHub Actions CI running a version bump
caller: { requested_by: { identity: "gh:LegionIO/legion/ci", type: :workload, credential: :jwt } }
agent: nil

# Call center bot assisting a customer, using GAIA
caller: {
  requested_by: { identity: "service:call-center-bot", type: :bot, credential: :mtls },
  requested_for: { identity: "customer:12345", type: :customer,
                   relationship: "inbound support call" }
}
agent: { id: "gaia", name: "GAIA", type: :autonomous }

# Internal daemon running scheduled task
caller: { requested_by: { identity: "service:legionio-daemon", type: :service, credential: :internal } }
agent: { id: "agent_scheduler", name: "Scheduler", type: :system }
```

### RBAC and caller

RBAC checks `caller.requested_by` for permission evaluation. If `requested_for` is present, RBAC can also check: "Does this bot have permission to act on behalf of this customer?" Billing can route costs to `requested_for` instead of `requested_by`.

### Credential types

- `:jwt` -- JSON Web Token (GitHub Actions, workload identity, OIDC)
- `:api_key` -- API key authentication
- `:session` -- browser/CLI session token
- `:mtls` -- mutual TLS certificate
- `:internal` -- internal service-to-service (trusted, no external credential)

---

## Agent Identity

Tracks which AI entity is executing the request. Not about auth (that's `caller`) -- about the AI agent doing the work.

```
agent:             Hash?
  id:              String       # unique agent identifier
  name:            String       # human-readable name
  type:            Symbol       # :human, :autonomous, :supervised, :system
  delegation_chain: Array<Hash>  # who asked who asked who
  task_id:         String?      # what higher-level task this serves
  goal:            String?      # what the agent is trying to accomplish
```

### Agent types

- `:human` -- direct human interaction (CLI, chat, interlink)
- `:autonomous` -- agent operating independently (GAIA, scheduled tasks)
- `:supervised` -- agent operating with human oversight
- `:system` -- system-level operations (health checks, maintenance)

### Delegation chain

```
delegation_chain: [
  { id: "user_matt", type: "human", name: "Matt" },
  { id: "agent_planner", type: "autonomous", name: "Planning Agent" },
  { id: "agent_coder", type: "autonomous", name: "Coding Agent" }
]
# Coding Agent is making the request, delegated by Planning Agent,
# which was started by Matt.
```

RBAC can check: "Coding Agent is acting on behalf of Matt. Does Matt have permission to use cloud providers?" The entire chain is auditable.

### Task context

```
task_id: "task_abc123"     # links to a higher-level task/goal
goal: "Refactor auth module to use JWT tokens"
```

Multiple LLM requests can share a `task_id`, enabling: "Show me everything that happened while working on this task."

---

## Billing & Budget

Cost tracking, budget enforcement, and rate limiting.

```
billing:           Hash?
  cost_center:     String?      # which budget/department pays
  budget_id:       String?      # specific budget allocation
  rate_limit_key:  String?      # which rate limit bucket to count against
  spending_cap:    Float?       # max USD for this single request
```

### On request

Declares who pays and what the limits are:
```
billing: {
  cost_center: "engineering-platform",
  budget_id: "budget_q1_2026",
  spending_cap: 0.50
}
```

### On response

Actual cost is in `response.cost` (already defined). Combined with billing:
```
request.billing[:spending_cap]   # $0.50 (my limit)
response.cost[:estimated_usd]    # $0.004 (what it cost)
# Under budget. If cost would exceed cap, request is rejected pre-call.
```

### Budget enforcement

Checked in the pipeline before the provider call:
- Sum previous costs for this `budget_id`
- Estimate cost of this request (token estimate * provider pricing)
- If estimated total exceeds budget: reject with `:budget_exceeded` error
- Enrichment: "budget check passed, $4.23 of $100.00 remaining"

---

## Test & Evaluation Mode

Controls for testing, benchmarking, replay, and experimentation.

```
test:              Hash?
  enabled:         Boolean      # is this a test request?
  mode:            Symbol       # :mock, :record, :replay, :shadow
  replay_id:       String?      # replay this previous request (mode: :replay)
  ground_truth:    String?      # known correct answer for benchmarking
  eval_criteria:   Array<String>?  # what makes a good response
  experiment:      Hash?        # A/B test context
    name:          String       # experiment name
    variant:       String       # which variant (e.g., "with_gaia", "without_gaia")
    group:         String       # control or treatment
```

### Test modes

- `:mock` -- don't call the provider. Return a canned/mock response. For unit testing.
- `:record` -- call the provider normally, but save the full request+response pair for future replay.
- `:replay` -- replay a previously recorded request exactly. `replay_id` references the recorded pair.
- `:shadow` -- call the provider but don't return the response to the caller. For comparison testing against production traffic.

### Ground truth & evaluation

For benchmarking and quality measurement:
```
test: {
  enabled: true,
  mode: :record,
  ground_truth: "The function should return a sorted array of unique values.",
  eval_criteria: ["correctness", "conciseness", "code_quality"]
}
```

Response quality score is compared against ground truth. Over many requests, this builds a benchmark dataset.

### Experiments

For A/B testing:
```
# Variant A: with GAIA shaping
test: { experiment: { name: "gaia_value", variant: "with_gaia", group: "treatment" } }

# Variant B: without GAIA shaping
test: { experiment: { name: "gaia_value", variant: "without_gaia", group: "control" } }
```

Experiment results are tracked via predictions (expected: better quality with GAIA) and compared across variants.

---

## Modality

Declares input and output modality expectations. Guides routing (not all providers support all combinations) and future-proofs for multimodal evolution.

```
modality:          Hash?
  input:           Array<Symbol>   # what's being sent
  output:          Array<Symbol>   # what's wanted back
  preferences:     Hash?           # additional modality preferences
```

### Modality values

```
:text       # text content
:image      # image content
:audio      # audio content
:video      # video content
:document   # document content (PDF, etc.)
:code       # explicit code output (vs text with code in it)
```

### Examples

```
# Text in, text out (default)
modality: { input: [:text], output: [:text] }

# Image analysis
modality: { input: [:text, :image], output: [:text] }

# Transcription
modality: { input: [:audio], output: [:text] }

# Text to speech (future)
modality: { input: [:text], output: [:audio] }

# Code generation with preference
modality: { input: [:text], output: [:text, :code],
            preferences: { language: "ruby", prefer_code: true } }
```

### Routing impact

Router checks provider capabilities against requested modalities:
```
Request needs: input: [:text, :image], output: [:text]
Provider capabilities:
  ollama:  { vision: false } → filtered out
  claude:  { vision: true }  → eligible
  openai:  { vision: true }  → eligible
  gemini:  { vision: true }  → eligible
```

---

## Lifecycle Hooks

Caller-declared injection points in the pipeline. Named hooks registered by extensions or configuration.

```
hooks:             Hash?
  before_routing:  Array<String>?  # run before provider selection
  after_routing:   Array<String>?  # run after provider selection
  before_call:     Array<String>?  # run before provider call
  after_response:  Array<String>?  # run after response received
  on_tool_call:    Array<String>?  # run when a tool is called
  on_error:        Array<String>?  # run on failure
  on_escalation:   Array<String>?  # run when provider is escalated
```

### How hooks work

Extensions register hooks by name:
```ruby
Legion::LLM.register_hook("log_to_splunk") do |event|
  Splunk.log(event)
end

Legion::LLM.register_hook("notify_slack_on_escalation") do |event|
  Slack.post("#llm-alerts", "Escalation: #{event.reason}")
end
```

Requests declare which hooks to run:
```
hooks: {
  after_response: ["log_to_splunk"],
  on_escalation: ["notify_slack_on_escalation", "log_to_splunk"]
}
```

Hooks receive the full request/response context and can add enrichments, but cannot modify the request or response (read-only observers, not interceptors).

---

## Feedback

User or automated quality feedback on specific messages. Lives on the Conversation, not on individual requests. Closes the learning loop.

```
Feedback
  id:              String       # unique feedback ID
  message_id:      String       # which message is being rated
  conversation_id: String       # which conversation
  rating:          Symbol       # :positive, :negative, :neutral
  score:           Integer?     # 1-5 scale (optional finer granularity)
  correction:      String?      # what the right answer should have been
  tags:            Array<String>  # categorization: ["inaccurate", "too_verbose",
                                #   "wrong_tool", "hallucination", "perfect"]
  source:          Symbol       # :user, :automated, :gaia, :quality_checker
  timestamp:       Time
```

### Feedback flow

```
1. User sees response (msg_002)
2. User gives thumbs down
3. Feedback recorded: { message_id: "msg_002", rating: :negative,
                        tags: ["wrong_tool"], correction: "should have used search, not list" }
4. Feedback published to RMQ alongside audit events
5. GAIA consumes feedback, correlates with predictions:
   - Router predicted "list_files is the right tool" (confidence 0.9)
   - User said "should have used search" (rating: negative)
   - GAIA learns: when user says "find X in the codebase", prefer search over list
```

### Automated feedback

Quality checkers and GAIA can also submit feedback:
```
{ source: :quality_checker, rating: :negative,
  tags: ["too_short"], score: 2 }

{ source: :gaia, rating: :positive,
  tags: ["efficient_tool_use"], score: 5 }
```

---

## Audit

Record of what *happened* during pipeline processing -- decisions, actions, outcomes. Separate from enrichments (which record what *shaped* the request). Response-only.

Audit is a **Hash keyed by `"step:action"`**, same pattern as enrichments and predictions.

```
audit:             Hash<String, AuditEvent>

# Key format: "step:action"
# Value:
AuditEvent
  outcome:         Symbol       # :success, :failure, :degraded, :skipped
  detail:          String       # human-readable description
  data:            Hash?        # structured data
  duration_ms:     Integer?
  timestamp:       Time
```

### Enrichment vs Audit

| | Enrichments | Audit |
|---|---|---|
| **What** | Things that *shaped* the request | Things that *happened* during processing |
| **When** | Request + Response | Response only |
| **Examples** | GAIA injecting context, RAG retrieving messages, MCP registering tools | RBAC granting permission, classification upgrade, budget check, persistence status |

### Standard audit keys

```ruby
# Pipeline decisions
"rbac:permission_check"       # RBAC granted or denied access
"classification:scan"         # System scanned content, may have upgraded classification
"billing:budget_check"        # Budget check passed/failed
"routing:provider_selection"  # Provider selected and why
"routing:modality_filter"     # Providers filtered by modality capability

# Pipeline outcomes
"persistence:store"           # Conversation stored (direct or spooled)
"persistence:semantic_index"  # Apollo/pgvector embedding queued
"transport:audit_publish"     # Audit event published to RMQ
"cache:lookup"                # Cache hit/miss
"cache:store"                 # Response cached
```

### Example

```ruby
response.audit = {
  "rbac:permission_check":      { outcome: :success, detail: "caller user:matt permitted",
                                  duration_ms: 2, timestamp: Time.now },
  "classification:scan":        { outcome: :success,
                                  detail: "caller declared :internal, no upgrade needed",
                                  data: { declared: :internal, effective: :internal,
                                          upgraded: false },
                                  duration_ms: 8, timestamp: Time.now },
  "billing:budget_check":       { outcome: :success,
                                  detail: "budget check passed, $4.23 of $100.00 remaining",
                                  data: { remaining_usd: 95.77 },
                                  duration_ms: 3, timestamp: Time.now },
  "routing:provider_selection": { outcome: :success,
                                  detail: "selected claude via smart strategy",
                                  data: { strategy: :smart, candidates: 3 },
                                  duration_ms: 5, timestamp: Time.now },
  "persistence:store":          { outcome: :success,
                                  detail: "conversation stored, 2 messages",
                                  data: { method: :direct, store: "postgresql" },
                                  duration_ms: 12, timestamp: Time.now },
  "transport:audit_publish":    { outcome: :success,
                                  detail: "audit event published to llm.audit exchange",
                                  duration_ms: 3, timestamp: Time.now }
}
```

### Classification upgrade in audit

When the system detects content at a higher classification than the caller declared:

```ruby
"classification:scan": {
  outcome: :success,
  detail: "caller declared :internal, system detected PHI, upgraded to :restricted",
  data: {
    declared: :internal,       # what the caller said
    effective: :restricted,    # what the system determined
    upgraded: true,
    reason: "PHI detected in message content"
  },
  duration_ms: 15,
  timestamp: Time.now
}
# response.classification now reflects :restricted, not :internal
```

Classification can only be upgraded, never downgraded. If the caller says `:restricted` but the system sees no sensitive data, it stays `:restricted`.

### Direct lookup

```ruby
response.audit[:"rbac:permission_check"][:outcome]  # => :success
response.audit[:"classification:scan"][:data][:upgraded]  # => true
response.audit[:"persistence:store"][:data][:method]  # => :direct
```

---

## Pipeline Timeline

Inspired by [Homer/SIPCAPTURE](https://github.com/sipcapture/homer) call flow diagrams. A unified, globally-sequenced timeline of **everything** that happened during a request. Reconstructs the full call flow across all systems -- enrichments, audit, tool calls, provider calls, connections -- in one ordered record.

This is the **one place an array is correct**. Timeline is ordered data, not lookup data. You iterate it in sequence to reconstruct the call flow, like Homer's ladder diagram.

```
timeline:          Array<TimelineEvent>   # ordered by seq

TimelineEvent
  seq:             Integer       # global sequence across ALL event types
  exchange_id:     String?       # which exchange (hop/leg) this event belongs to
                                 # nil for pipeline-level events (tracing:init, uuid:resolve)
                                 # set for provider calls, tool executions, retries
  timestamp:       Time          # when this event occurred
  category:        Symbol        # :enrichment, :audit, :provider, :tool,
                                 # :connection, :internal
  key:             String        # references enrichment/audit key or describes event
                                 # "rag:context_retrieval", "rbac:permission_check",
                                 # "provider:request_sent", "tool:list_files:execute"
  direction:       Symbol?       # :inbound, :outbound, :internal
  from:            String?       # source component
  to:              String?       # destination component
  detail:          String        # human-readable description
  duration_ms:     Integer?      # how long (nil for instantaneous events)
  data:            Hash?         # structured payload
```

### Why timeline exists alongside enrichments and audit

Enrichments and audit are **keyed hashes for lookup**: "What did GAIA contribute?" → `enrichments[:"gaia:system_prompt"]`. "Did RBAC pass?" → `audit[:"rbac:permission_check"][:outcome]`.

Timeline is the **chronological reconstruction**: "Show me everything that happened, in order, for this request." It references enrichment and audit keys but adds provider calls, tool executions, connection events, and internal pipeline steps that don't belong in either hash.

### Example timeline

```ruby
response.timeline = [
  { seq: 1,  timestamp: t0,       category: :internal,    key: "tracing:init",
    direction: :internal, detail: "trace initialized", from: "pipeline", to: "pipeline" },
  { seq: 2,  timestamp: t0+1,     category: :internal,    key: "uuid:resolve",
    direction: :internal, detail: "conversation conv_xyz789 loaded (3 messages)",
    from: "pipeline", to: "conversation_store" },
  { seq: 3,  timestamp: t0+2,     category: :audit,       key: "rbac:permission_check",
    direction: :internal, detail: "caller user:matt permitted",
    from: "pipeline", to: "rbac" },
  { seq: 4,  timestamp: t0+5,     category: :audit,       key: "classification:scan",
    direction: :internal, detail: "no upgrade needed",
    from: "pipeline", to: "classification" },
  { seq: 5,  timestamp: t0+8,     category: :audit,       key: "billing:budget_check",
    direction: :internal, detail: "$4.23 of $100.00 remaining",
    from: "pipeline", to: "billing" },
  { seq: 6,  timestamp: t0+10,    category: :enrichment,  key: "rag:context_retrieval",
    direction: :outbound, detail: "15 of 400 messages selected",
    from: "pipeline", to: "apollo", duration_ms: 120 },
  { seq: 7,  timestamp: t0+130,   category: :enrichment,  key: "mcp:tool_registration",
    direction: :outbound, detail: "8 tools from 2 servers",
    from: "pipeline", to: "mcp:filesystem", duration_ms: 1500 },
  { seq: 8,  timestamp: t0+1630,  category: :audit,       key: "routing:provider_selection",
    direction: :internal, detail: "selected claude via smart strategy",
    from: "router", to: "pipeline" },
  { seq: 9,  timestamp: t0+1635,  category: :connection,  key: "connection:checkout",
    exchange_id: "exch_001",
    direction: :outbound, detail: "connection reused from pool",
    from: "pipeline", to: "provider:claude",
    data: { pool_id: "claude_pool", reused: true } },
  { seq: 10, timestamp: t0+1640,  category: :provider,    key: "provider:request_sent",
    exchange_id: "exch_001",
    direction: :outbound, detail: "POST https://api.anthropic.com/v1/messages",
    from: "pipeline", to: "provider:claude" },
  { seq: 11, timestamp: t0+3400,  category: :provider,    key: "provider:response_received",
    exchange_id: "exch_001",
    direction: :inbound,  detail: "200 OK, tool_use, 1 tool call",
    from: "provider:claude", to: "pipeline", duration_ms: 1760 },
  { seq: 12, timestamp: t0+3405,  category: :tool,        key: "tool:list_files:execute",
    exchange_id: "exch_002",
    direction: :outbound, detail: "executing list_files via mcp:filesystem",
    from: "pipeline", to: "mcp:filesystem", duration_ms: 45 },
  { seq: 13, timestamp: t0+3450,  category: :tool,        key: "tool:list_files:result",
    exchange_id: "exch_002",
    direction: :inbound,  detail: "tool returned 3 results",
    from: "mcp:filesystem", to: "pipeline" },
  { seq: 14, timestamp: t0+3455,  category: :provider,    key: "provider:request_sent",
    exchange_id: "exch_003",
    direction: :outbound, detail: "POST (with tool result)",
    from: "pipeline", to: "provider:claude" },
  { seq: 15, timestamp: t0+4200,  category: :provider,    key: "provider:response_received",
    exchange_id: "exch_003",
    direction: :inbound,  detail: "200 OK, end_turn",
    from: "provider:claude", to: "pipeline", duration_ms: 745 },
  { seq: 16, timestamp: t0+4210,  category: :audit,       key: "persistence:store",
    direction: :outbound, detail: "conversation stored, 4 messages",
    from: "pipeline", to: "postgresql" },
  { seq: 17, timestamp: t0+4215,  category: :audit,       key: "transport:audit_publish",
    direction: :outbound, detail: "audit event published",
    from: "pipeline", to: "rmq:llm.audit" },
  { seq: 18, timestamp: t0+4220,  category: :connection,  key: "connection:return",
    exchange_id: "exch_003",
    direction: :internal, detail: "connection returned to pool",
    from: "pipeline", to: "provider:claude" }
]
```

### Homer-style visualization

The timeline enables a ladder diagram identical to Homer's call flow:

```
    pipeline    rbac    apollo    mcp    router    claude    postgresql    rmq
       │         │        │        │       │         │           │          │
  [1]  ├─init────┤        │        │       │         │           │          │
  [3]  ├────────►│        │        │       │         │           │          │
       │◄────ok──┤        │        │       │         │           │          │
  [6]  ├─────────────────►│        │       │         │           │          │
       │◄──15 msgs────────┤        │       │         │           │          │
  [7]  ├──────────────────────────►│       │         │           │          │
       │◄──8 tools─────────────────┤       │         │           │          │
  [8]  ├───────────────────────────────────►│         │           │          │
       │◄──claude──────────────────────────┤         │           │          │
  [10] ├─────────────────────────────────────────────►│           │          │
  [11] │◄───────────────────────────────200 OK────────┤           │          │
  [12] ├──────────────────────────►│       │         │           │          │
  [13] │◄──result──────────────────┤       │         │           │          │
  [14] ├─────────────────────────────────────────────►│           │          │
  [15] │◄───────────────────────────────200 OK────────┤           │          │
  [16] ├──────────────────────────────────────────────────────────►│          │
  [17] ├─────────────────────────────────────────────────────────────────────►│
```

### Timeline is response-only

The timeline is built during pipeline execution and returned on the response. It's not sent on the request.

---

## Participants

All systems that touched this request. Enables Homer-style column headers for call flow visualization. Response-only, populated by the pipeline.

```
participants:      Array<String>   # ordered by first appearance in timeline
```

### Example

```ruby
response.participants = [
  "pipeline",          # Legion::LLM pipeline itself
  "rbac",              # RBAC permission check
  "classification",    # classification scanner
  "billing",           # budget check
  "apollo",            # RAG retrieval (semantic index)
  "mcp:filesystem",    # MCP tool server
  "router",            # routing engine
  "provider:claude",   # LLM provider
  "postgresql",        # conversation store
  "rmq:llm.audit"     # audit transport
]
```

Auto-populated: every unique `from` and `to` value in the timeline becomes a participant.

---

## Wire Capture

Raw request and response payloads as sent to/received from the provider. For debugging translator issues, you need both sides of the wire. Opt-in (can be expensive to store).

Keyed by `exchange_id` -- one capture per provider call, not per request. A request with retries or tool loops produces multiple wire captures.

```
wire:              Hash<String, WireCapture>?   # keyed by exchange_id, nil by default

WireCapture
  exchange_id:     String             # which exchange this capture belongs to
  request:         Hash?              # what was sent TO the provider (post-translation)
  response:        Hash?              # what was received FROM the provider (pre-translation)
  endpoint:        String?            # actual URL/endpoint hit
  method:          String?            # HTTP method ("POST")
  status:          Integer?           # HTTP status code (200, 429, etc.)
  headers:         Hash?              # request headers sent (redacted auth)
  response_headers: Hash?             # response headers received
```

### Why keyed by exchange

A single request can hit the wire multiple times:

```
request req_abc123:
  wire["exch_001"] → POST ollama → 500 (retry)
  wire["exch_002"] → POST ollama → 500 (escalate)
  wire["exch_003"] → POST claude → 200 (tool_use)
  wire["exch_004"] → POST claude → 200 (end_turn)
```

With a single wire hash you'd only see the last exchange. Keying by exchange_id preserves the full record.

### Why both sides

The existing `raw` field only captures the provider response. But translator bugs can be on either side:
- **Outbound bug**: "We sent tools in the wrong format to Gemini" -- need `wire[exch].request`
- **Inbound bug**: "Bedrock returned content blocks we didn't parse" -- need `wire[exch].response`
- **Network issue**: "Got 502 but no body" -- need `wire[exch].status` and `wire[exch].response_headers`

### Opt-in control

```ruby
# Per-request
Legion::LLM.chat(messages: [...], extra: { wire_capture: true })

# Global setting
Legion::Settings[:llm][:wire_capture] = true  # capture all
Legion::Settings[:llm][:wire_capture] = :errors_only  # capture on non-200
```

### Connection context

Provider connection metadata, captured per-request:

```
connection:        Hash?              # on response.routing
  pool_id:         String?            # which connection pool
  reused:          Boolean?           # new or reused connection
  tls_version:     String?            # "TLSv1.3"
  endpoint:        String?            # actual URL/host hit
  connect_ms:      Integer?           # connection setup time (0 if reused)
```

This lives on `response.routing.connection` since it's part of the routing outcome.

---

## Retry

Distinct from escalation. Retries are the same provider/model attempted again after a transient failure. Escalation is switching to a different provider/model.

```
retry:             Hash?              # response-only
  attempts:        Integer            # total attempts (1 = no retries)
  max_attempts:    Integer            # configured limit
  history:         Array<Hash>        # one entry per failed attempt
    attempt:       Integer            # 1, 2, 3...
    exchange_id:   String             # which exchange this attempt corresponds to
    error:         Symbol             # :provider_error, :rate_limit, :timeout
    status:        Integer?           # HTTP status code
    message:       String             # error detail
    backoff_ms:    Integer            # how long we waited before retrying
    timestamp:     Time
```

### Retry vs Escalation

```
Retry:      claude 500 → wait 2s → claude again → success (attempt 2)
Escalation: ollama can't handle → switch to claude (different provider)

# Both can happen in sequence:
# claude 500 → retry claude → claude 500 again → escalate to openai
```

### Example

```ruby
response.retry = {
  attempts: 2,
  max_attempts: 3,
  history: [
    { attempt: 1, exchange_id: "exch_01HZ3G4K7P0001",
      error: :provider_error, status: 500,
      message: "Internal Server Error", backoff_ms: 2000,
      timestamp: Time.now }
  ]
}
# attempt 1 failed (exch_001), attempt 2 succeeded (exch_002), history only records failures
```

---

## Content Safety

Provider-reported content filtering results. Different from classification (which is our data governance). This is the provider saying "I evaluated this content against my safety policies."

Response-only. Not all providers return this.

```
safety:            Hash?
  flagged:         Boolean            # was anything flagged?
  categories:      Hash<String, SafetyResult>  # keyed by category name
```

```
SafetyResult
  filtered:        Boolean            # was content actually blocked?
  severity:        Symbol             # :safe, :low, :medium, :high
  score:           Float?             # 0.0 to 1.0 confidence
```

### Provider mapping

| Provider | Categories | Notes |
|----------|-----------|-------|
| Azure OpenAI | hate, self_harm, sexual, violence | Always present, per-choice + per-prompt |
| Anthropic | (none structured) | Safety via stop_reason: "safety" |
| OpenAI | (via Moderation API) | Separate call, not inline |
| Gemini | harassment, hate_speech, sexually_explicit, dangerous_content | Safety ratings array |

### Example

```ruby
response.safety = {
  flagged: false,
  categories: {
    "hate":      { filtered: false, severity: :safe },
    "self_harm": { filtered: false, severity: :safe },
    "sexual":    { filtered: false, severity: :safe },
    "violence":  { filtered: false, severity: :safe }
  }
}

# When content IS flagged:
response.safety = {
  flagged: true,
  categories: {
    "hate":      { filtered: true,  severity: :high, score: 0.92 },
    "violence":  { filtered: false, severity: :low,  score: 0.15 }
  }
}
```

---

## Rate Limit State

Provider quota state returned in response headers. Structured and always captured (not opt-in like wire). Critical for routing decisions.

```
rate_limit:        Hash?              # response-only, nil if provider doesn't report
  requests:        Hash?
    remaining:     Integer            # requests remaining in window
    limit:         Integer            # total requests allowed in window
    reset_at:      Time               # when the window resets
  tokens:          Hash?
    remaining:     Integer            # tokens remaining in window
    limit:         Integer            # total tokens allowed in window
    reset_at:      Time
```

### Provider header mapping

| Provider | Request headers | Token headers |
|----------|----------------|---------------|
| Anthropic | `anthropic-ratelimit-requests-remaining` | `anthropic-ratelimit-tokens-remaining` |
| OpenAI | `x-ratelimit-remaining-requests` | `x-ratelimit-remaining-tokens` |
| Azure | `x-ratelimit-remaining-requests` | `x-ratelimit-remaining-tokens` |
| Bedrock | (via throttling exceptions) | (via throttling exceptions) |
| Gemini | (via 429 response) | (via 429 response) |

### How rate_limit feeds routing

```ruby
# After each response, update provider health:
if response.rate_limit&.dig(:requests, :remaining)&.< 5
  health_tracker.report(provider: :claude, signal: :quota_low,
                        value: response.rate_limit[:requests][:remaining])
  # Router shifts traffic to other providers before hitting the wall
end
```

---

## Thinking & Reasoning

Controls for extended thinking, chain-of-thought, and reasoning behavior. Separate from generation parameters (temperature, top_p) because reasoning is about *how deeply* the model thinks, not *how randomly* it samples.

### Request side

```
thinking:          Hash?
  enabled:         Boolean            # enable extended thinking / chain-of-thought
  budget_tokens:   Integer?           # max tokens for thinking (Anthropic)
  effort:          Symbol?            # :low, :medium, :high (OpenAI reasoning_effort)
```

### Response side

```
thinking:          Hash?
  tokens:          Integer            # thinking tokens consumed
  truncated:       Boolean            # did thinking hit budget_tokens limit?
```

### Provider mapping

| Provider | Request | Response |
|----------|---------|----------|
| Anthropic | `thinking: { type: "enabled", budget_tokens: N }` | Thinking content blocks + `usage.cache_creation_input_tokens` |
| OpenAI | `reasoning_effort: "high"` | Reasoning tokens in usage |
| Gemini | `generationConfig.thinkingConfig` | Thinking in parts |
| Others | (not supported -- ignored by translator) | |

Thinking tokens are tracked separately from regular output tokens because they have different pricing and different utility. Response `thinking.tokens` does NOT count toward `tokens.output`.

---

## Context Window Utilization

Expands response-side tokens with capacity information. Drives context strategy decisions.

Added to `response.tokens`:

```
tokens:            Hash
  # Existing fields
  max:             Integer      # echoed from request
  input:           Integer
  output:          Integer
  total:           Integer
  cache_read:      Integer?
  cache_create:    Integer?

  # New: capacity awareness
  context_window:  Integer      # provider's maximum context window for this model
  utilization:     Float        # total / context_window (0.0 to 1.0)
  headroom:        Integer      # context_window - total (remaining capacity)
```

### How utilization drives decisions

```ruby
if response.tokens[:utilization] > 0.80
  # Switch to RAG for next request -- context is getting full
  next_request.context_strategy = :rag
end

if response.tokens[:utilization] > 0.95
  # Compress or summarize before next request
  next_request.context_strategy = :rag
  # Consider escalating to a larger-context model
end

if response.tokens[:headroom] < 1000
  # Not enough room for a meaningful response
  # Trigger context compaction
end
```

---

## Structured Output Validation

When `response_format.type` is `:json` or `:json_schema`, reports whether the response actually validated.

Response-only. Added to response alongside quality.

```
validation:        Hash?              # nil if response_format.type was :text
  valid:           Boolean            # did the response conform?
  format:          Symbol             # :json, :json_schema (echoed from request)
  errors:          Array<Hash>?       # validation errors (nil if valid)
    path:          String             # JSON path to invalid field ("$.items[0].name")
    message:       String             # what was wrong
    expected:      String?            # expected type/value
    actual:        String?            # what was received
  repaired:        Boolean            # did Legion auto-repair the response?
  repair_method:   Symbol?            # :json_parse_fix, :schema_coerce, :retry
```

### Example

```ruby
# Valid response
response.validation = { valid: true, format: :json_schema }

# Invalid response
response.validation = {
  valid: false,
  format: :json_schema,
  errors: [
    { path: "$.items[0].count", message: "expected integer, got string",
      expected: "integer", actual: "\"five\"" }
  ],
  repaired: true,
  repair_method: :schema_coerce
}
```

---

## Provider Features

Post-hoc report of which provider-specific features actually activated on this request. Different from capabilities (what the provider CAN do) -- this is what it DID.

Response-only. Hash-keyed by feature name.

```
features:          Hash<String, Hash>?

# Standard feature keys:
"prompt_caching":    { hit: true,  tokens_saved: 15000 }
"search_grounding":  { used: false }
"extended_thinking": { used: true, budget: 10000, consumed: 4500 }
"batch_mode":        { used: false }
"streaming":         { used: true, chunks: 47 }
"json_mode":         { used: true, native: true }   # native vs prompt-based
"vision":            { used: true, images: 2 }
```

### Why this matters

Prompt caching can save 90% of input token costs. If you're paying full price because caching isn't activating, you need to know. Same for extended thinking -- if the model is spending 8000 thinking tokens on a simple request, the routing strategy needs adjusting.

```ruby
# "Are we getting value from prompt caching?"
if response.features&.dig("prompt_caching", :hit)
  savings = response.features["prompt_caching"][:tokens_saved] * cost_per_token
end

# "Is thinking budget right-sized?"
if response.features&.dig("extended_thinking", :consumed)
  ratio = response.features["extended_thinking"][:consumed].to_f /
          response.features["extended_thinking"][:budget]
  # ratio < 0.2 → budget too high, wasting money
  # ratio > 0.95 → budget too low, thinking got truncated
end
```

---

## Model Deprecation

Structured deprecation warnings from providers. Separate from the `warnings` array because automated systems need to act on these programmatically.

Response-only.

```
deprecation:       Hash?
  deprecated:      Boolean            # is the model used marked as deprecated?
  model:           String             # the deprecated model
  sunset_date:     String?            # ISO 8601 date when model will be removed
  replacement:     String?            # suggested replacement model
  message:         String             # provider's deprecation notice
```

### Example

```ruby
response.deprecation = {
  deprecated: true,
  model: "gpt-4-0613",
  sunset_date: "2025-06-13",
  replacement: "gpt-4o",
  message: "This model is deprecated. Migrate to gpt-4o by June 13, 2025."
}
```

### Automated response

```ruby
if response.deprecation&.fetch(:deprecated, false)
  # Publish event for ops alerting
  Legion::Transport.publish("llm.deprecation", {
    model: response.deprecation[:model],
    replacement: response.deprecation[:replacement],
    sunset_date: response.deprecation[:sunset_date]
  })

  # Update routing rules to prefer replacement
  # (human reviews, doesn't auto-switch)
end
```

---

## Cache

Symmetric caching controls on request and response. Replaces a flat strategy symbol with structured metadata.

### Request side (what I want)

```
cache:             Hash
  strategy:        Symbol       # :default, :no_cache, :cache_only, :refresh
  ttl:             Integer?     # seconds to cache this response (nil = system default)
  key:             String?      # explicit cache key (nil = auto-generated from content hash)
  tier:            Symbol?      # :local, :shared, :any (which cache layer to check/store)
  cacheable:       Boolean      # can this response be cached at all? (default true)
```

### Response side (what happened)

```
cache:             Hash
  hit:             Boolean      # was this served from cache?
  key:             String?      # the cache key used
  tier:            Symbol?      # :local, :shared (which layer served it, nil if miss)
  age:             Integer?     # seconds since originally cached (nil if miss)
  expires_in:      Integer?     # seconds until this cache entry expires
  stored_at:       Time?        # when the cached response was originally generated
```

### Cache strategies

- `:default` -- check cache first, call provider on miss, cache result
- `:no_cache` -- skip cache entirely, always call provider, don't cache result
- `:cache_only` -- only return cached response, fail if not cached
- `:refresh` -- call provider regardless, update cache with new result

### Cache tiers

- `:local` -- in-memory + local Redis. Private to this node. Fast.
- `:shared` -- shared Redis/PG. Team-visible, RBAC-controlled. Slower.
- `:any` -- check local first, then shared (default behavior)

### Cache key generation

When `key` is nil (the default), the cache key is generated from a deterministic hash of:
- `system` prompt
- `messages` content (not IDs or timestamps)
- `tools` definitions
- `routing.model` (if explicit)
- `generation` parameters

This means identical prompts to the same model with the same tools produce cache hits even across conversations.

### Example flow

```
Request:  cache: { strategy: :default, ttl: 300, tier: :any, cacheable: true }
Pipeline: check local cache → miss → check shared cache → miss → call provider
Response: cache: { hit: false, key: "sha256:abc123", tier: nil }
          (response is then stored to local cache with ttl: 300)

Next identical request:
Pipeline: check local cache → HIT
Response: cache: { hit: true, key: "sha256:abc123", tier: :local, age: 45, expires_in: 255,
                   stored_at: "2026-03-23T10:00:02Z" }
```

---

## Request

What goes into the Legion::LLM pipeline.

```
Request
  # Identification
  id:                String       # unique request ID
  conversation_id:   String?      # nil = auto-generate UUID
  idempotency_key:   String?      # deduplication key
  schema_version:    String       # "1.0.0"

  # Content
  system:            String | Array<ContentBlock>
  messages:          Array<Message>

  # Tools
  tools:             Array<Tool>
  tool_choice:       ToolChoice

  # Routing (symmetric with response)
  routing:           Hash
    provider:        Symbol?      # hint, router may override
    model:           String?      # hint, router may override

  # Tokens (symmetric with response)
  tokens:            Hash
    max:             Integer

  # Stop (symmetric with response)
  stop:              Hash
    sequences:       Array<String>

  # Generation (sampling parameters)
  generation:        Hash
    temperature:     Float?       # 0.0 to 2.0
    top_p:           Float?       # 0.0 to 1.0
    top_k:           Integer?     # Anthropic/Gemini
    seed:            Integer?     # OpenAI

  # Thinking / Reasoning (separate from sampling)
  thinking:          Hash?
    enabled:         Boolean      # enable extended thinking / chain-of-thought
    budget_tokens:   Integer?     # max tokens for thinking (Anthropic)
    effort:          Symbol?      # :low, :medium, :high (OpenAI reasoning_effort)

  # Response Format
  response_format:   Hash
    type:            Symbol       # :text, :json, :json_schema
    schema:          Hash?        # JSON Schema when type is :json_schema

  # Behavior
  stream:            Boolean
  fork:              Array<Symbol>?    # provider names for parallel execution
  context_strategy:  Symbol       # :auto, :full, :recent, :rag, :none
  cache:             Hash         # strategy, ttl, key, tier, cacheable (see Cache section)
  priority:          Symbol       # :low, :normal, :high, :critical
  ttl:               Integer?     # seconds before request is stale (queue expiry, not cache)

  # Extensibility
  extra:             Hash         # provider-specific passthrough
  metadata:          Hash         # caller identity, tags, passthrough
  enrichments:       Hash<String, Enrichment>   # keyed by "source:type", populated by pipeline
  predictions:       Hash<String, Prediction>   # keyed by "source:type", hypotheses before execution

  # Tracing (OpenTelemetry-compatible)
  tracing:           Hash?
    trace_id:        String       # groups all requests from one user action
    span_id:         String       # this specific request
    parent_span_id:  String?      # the request that spawned this one
    correlation_id:  String?      # business-level grouping
    baggage:         Hash?        # propagated context

  # Governance
  classification:    Hash?
    level:           Symbol       # :public, :internal, :confidential, :restricted
    contains_pii:    Boolean
    contains_phi:    Boolean
    jurisdictions:   Array<String>
    retention:       Symbol
    consent:         Hash?

  # Identity
  caller:            Hash?        # auth principal (see Caller section)
    requested_by:    Hash         #   identity, type, credential, name
    requested_for:   Hash?        #   identity, type, name, relationship
  agent:             Hash?        # AI entity (see Agent Identity section)
    id:              String
    name:            String
    type:            Symbol       # :human, :autonomous, :supervised, :system
    delegation_chain: Array<Hash>
    task_id:         String?
    goal:            String?

  # Cost control
  billing:           Hash?
    cost_center:     String?
    budget_id:       String?
    rate_limit_key:  String?
    spending_cap:    Float?

  # Testing
  test:              Hash?
    enabled:         Boolean
    mode:            Symbol       # :mock, :record, :replay, :shadow
    replay_id:       String?
    ground_truth:    String?
    eval_criteria:   Array<String>?
    experiment:      Hash?

  # Modality
  modality:          Hash?
    input:           Array<Symbol>
    output:          Array<Symbol>
    preferences:     Hash?

  # Hooks
  hooks:             Hash?
    before_routing:  Array<String>?
    after_routing:   Array<String>?
    before_call:     Array<String>?
    after_response:  Array<String>?
    on_tool_call:    Array<String>?
    on_error:        Array<String>?
    on_escalation:   Array<String>?
```

### Convenience accessors

```ruby
request.model     # shorthand for request.routing[:model]
request.provider  # shorthand for request.routing[:provider]
```

### context_strategy

Controls how the ContextBuilder assembles conversation history:

- `:auto` -- ContextBuilder decides (RAG if long, full if short)
- `:full` -- send entire conversation history (may hit context limits)
- `:recent` -- last N messages only, no RAG
- `:rag` -- force RAG retrieval even for short conversations
- `:none` -- no history, treat as one-shot even if conversation_id has history

### cache

See the [Cache](#cache) section for full struct definition. Summary of strategies:

- `:default` -- check cache first, call provider on miss, cache result
- `:no_cache` -- skip cache, always call provider
- `:cache_only` -- only return cached response, fail if not cached
- `:refresh` -- call provider regardless, update cache with new result

### priority

For queue ordering when requests go through RMQ:

- `:low` -- background tasks, batch processing
- `:normal` -- standard interactive requests
- `:high` -- user-facing, time-sensitive
- `:critical` -- system operations, escalation responses

---

## Response

What comes back from the Legion::LLM pipeline.

```
Response
  # Identification
  id:                String       # unique response ID
  request_id:        String       # links back to request
  conversation_id:   String       # always present
  schema_version:    String       # "1.0.0"

  # Content
  message:           Message

  # Routing (symmetric with request)
  routing:           Hash
    provider:        Symbol       # actual provider used
    model:           String       # actual model used
    strategy:        Symbol       # :explicit, :rules, :smart, :default
    reason:          String       # human-readable routing reason
    escalated:       Boolean
    escalation_chain: Array<Hash>?  # provider history if escalated
    latency_ms:      Integer
    connection:      Hash?        # provider connection context
      pool_id:       String?
      reused:        Boolean?
      tls_version:   String?
      endpoint:      String?
      connect_ms:    Integer?

  # Tokens (symmetric with request + capacity awareness)
  tokens:            Hash
    max:             Integer      # echoed from request
    input:           Integer
    output:          Integer
    total:           Integer
    cache_read:      Integer?     # Anthropic prompt caching
    cache_create:    Integer?
    context_window:  Integer      # provider's max context for this model
    utilization:     Float        # total / context_window (0.0 to 1.0)
    headroom:        Integer      # context_window - total

  # Thinking (response-side)
  thinking:          Hash?
    tokens:          Integer      # thinking tokens consumed (NOT counted in tokens.output)
    truncated:       Boolean      # did thinking hit budget_tokens limit?

  # Stop (symmetric with request)
  stop:              Hash
    reason:          Symbol       # :end_turn, :tool_calls, :max_tokens, :safety, :stop_sequence
    sequence:        String?      # which stop sequence was hit (nil if none)

  # Tools (symmetric with request)
  tools:             Array<ToolCall>   # tool calls made (empty if none)

  # Behavior
  stream:            Boolean      # was this streamed?
  cache:             Hash         # hit, key, tier, age, expires_in, stored_at (see Cache section)

  # Retry
  retry:             Hash?        # nil if no retries attempted
    attempts:        Integer      # total attempts (1 = no retries)
    max_attempts:    Integer
    history:         Array<Hash>  # one entry per failed attempt (each has exchange_id)

  # Timing
  timestamps:        Hash
    received:        Time         # when pipeline received the request
    provider_start:  Time         # when provider call began
    provider_end:    Time         # when provider call completed
    returned:        Time         # when response was returned to caller

  # Quality & Cost
  cost:              Hash
    estimated_usd:   Float        # based on token usage + provider pricing
    provider:        Symbol       # which provider's pricing
    model:           String       # which model's pricing
  quality:           Hash?        # nil if quality checking didn't run
    score:           Integer
    acceptable:      Boolean
    checker:         String       # which checker ran
  validation:        Hash?        # nil if response_format.type was :text
    valid:           Boolean
    format:          Symbol       # :json, :json_schema
    errors:          Array<Hash>?
    repaired:        Boolean
    repair_method:   Symbol?

  # Provider state
  safety:            Hash?        # provider content filtering results
    flagged:         Boolean
    categories:      Hash<String, SafetyResult>
  rate_limit:        Hash?        # provider quota state
    requests:        Hash?        # remaining, limit, reset_at
    tokens:          Hash?        # remaining, limit, reset_at
  features:          Hash<String, Hash>?   # provider features that activated
  deprecation:       Hash?        # model deprecation warning
    deprecated:      Boolean
    model:           String
    sunset_date:     String?
    replacement:     String?
    message:         String

  # Observability
  enrichments:       Hash<String, Enrichment>   # keyed by "source:type"
  predictions:       Hash<String, Prediction>   # keyed by "source:type", actuals filled in
  audit:             Hash<String, AuditEvent>   # keyed by "step:action", response-only
  timeline:          Array<TimelineEvent>        # globally sequenced pipeline call flow
  participants:      Array<String>               # all systems that touched this request
  warnings:          Array<String>     # non-fatal issues
  wire:              Hash<String, WireCapture>?  # keyed by exchange_id (opt-in)

  # Tracing (echoed + extended from request)
  tracing:           Hash?
    trace_id:        String
    span_id:         String
    parent_span_id:  String?
    correlation_id:  String?
    baggage:         Hash?

  # Identity & governance
  caller:            Hash?           # echoed from request
  classification:    Hash?           # EFFECTIVE classification (may be upgraded from request)
  agent:             Hash?           # echoed from request
  billing:           Hash?           # echoed from request
  test:              Hash?           # echoed from request
```

### Convenience accessors

```ruby
response.model     # shorthand for response.routing[:model]
response.provider  # shorthand for response.routing[:provider]
```

### response.warnings

Non-fatal issues that don't prevent the response but the caller should know about:

```
["Context was truncated: 400 messages -> 25 (provider window limit)",
 "RAG index unavailable, fell back to recent-N strategy",
 "GAIA was unavailable for pre-request shaping",
 "Persistence failed, message spooled for retry"]
```

### Symmetry with Request

```ruby
# Side-by-side comparison
request.routing[:model]       # "claude-opus-4-6" (what I asked for)
response.routing[:model]      # "claude-opus-4-6-20250415" (what I got)

request.routing[:provider]    # nil (let router decide)
response.routing[:provider]   # :ollama (router picked)
response.routing[:strategy]   # :smart

request.tokens[:max]          # 4096 (my limit)
response.tokens[:input]       # 1245 (what went in)
response.tokens[:output]      # 89 (what came out)
response.tokens[:total]       # 1334 (total)
response.tokens[:max]         # 4096 (echoed back)

request.stop[:sequences]      # ["\n\n---"]
response.stop[:reason]        # :end_turn
response.stop[:sequence]      # nil (didn't hit one)

request.tools.map(&:name)     # ["list_files", "read_file"]
response.tools.map(&:name)    # ["read_file"] (what was called)

request.cache[:strategy]      # :default (what I want)
response.cache[:hit]          # false (cache miss)
response.cache[:age]          # nil (nothing was cached)

request.enrichments            # {} (empty before pipeline)
response.enrichments           # { "rag:context_retrieval" => {...}, ... }

request.predictions            # { "router:tool_usage" => { expected: true } }
response.predictions           # { "router:tool_usage" => { expected: true, actual: true, correct: true } }

# Response-only (no request-side equivalent)
response.audit                 # { "rbac:permission_check" => {...}, ... }
response.timeline              # [{ seq: 1, ... }, { seq: 2, ... }]
response.participants          # ["pipeline", "rbac", "provider:claude", ...]
```

---

## Chunk (Streaming)

Incremental data during a streamed response.

```
Chunk
  request_id:          String
  conversation_id:     String
  exchange_id:         String      # which exchange is streaming
  index:               Integer     # chunk sequence number
  type:                Symbol      # :content_delta, :thinking_delta,
                                   # :tool_call_delta, :usage, :done, :error
  content_block_index: Integer?    # which content block this delta belongs to
  delta:               String?     # text content delta
  tool_call:           ToolCall?   # partial tool call data
  usage:               Hash?       # token usage (on :done)
  stop_reason:         Symbol?     # (on :done)
  tracing:             Hash?       # trace_id, span_id (echoed from request)
```

### Chunk types

- `:content_delta` -- text content being streamed
- `:thinking_delta` -- reasoning trace being streamed (separate from content)
- `:tool_call_delta` -- tool call being assembled incrementally
- `:usage` -- token usage data (may arrive before :done on some providers)
- `:done` -- stream complete, includes final usage and stop_reason
- `:error` -- error occurred during streaming

---

## ErrorResponse

Standard error format for failed requests.

```
ErrorResponse
  id:                String       # unique error ID
  request_id:        String       # what request failed
  conversation_id:   String?
  schema_version:    String       # "1.0.0"
  error:             Symbol       # error type (see below)
  message:           String       # human-readable error message
  provider:          Symbol?      # which provider failed (nil if pre-routing)
  retryable:         Boolean      # should the caller retry?
  retry_after:       Integer?     # seconds to wait (rate limits)
  enrichments:       Hash<String, Enrichment>  # what shaped the request before failure
  audit:             Hash<String, AuditEvent>  # what happened during processing
  tracing:           Hash?        # trace_id, span_id (echoed from request)
  timestamps:        Hash
    received:        Time
    failed:          Time
```

### Error types

```
:auth                # 401 - invalid/missing credentials
:forbidden           # 403 - RBAC denied
:rate_limit          # 429 - provider rate limited
:context_overflow    # 400 - payload exceeds context window
:provider_error      # 502 - provider returned an error
:provider_down       # 503 - provider unavailable
:no_providers        # 503 - no available providers in pool
:unsupported         # 400 - requested capability not supported
:timeout             # 504 - request timed out
:stale               # 410 - TTL expired before processing
:duplicate           # 409 - idempotency key already processed
:invalid_request     # 400 - malformed request
:store_unavailable   # 503 - conversation store unreachable
:internal            # 500 - unexpected internal error
```

---

## Conversation

The persistent conversation object stored in the ConversationStore.

```
Conversation
  id:                String       # UUID
  title:             String?      # auto-generated or user-set
  summary:           String?      # auto-generated conversation summary
  system:            String?      # system prompt
  messages:          Array<Message>
  state:             Symbol       # :active, :completed, :archived
  shared:            Boolean      # local vs shared cache tier

  # Lineage
  parent_id:         String?      # forked from this conversation
  branch_point:      Integer?     # seq in parent where fork happened

  # People
  creator:           String       # caller identity who started this
  participants:      Array<String>  # all contributors

  # Organization
  tags:              Array<String>   # for search and categorization
  pinned:            Array<String>   # pinned message IDs

  # Aggregates
  usage_total:       Hash
    input:           Integer
    output:          Integer
    total:           Integer
    cost_usd:        Float
  routing_history:   Array<Hash>     # every provider decision made

  # Timestamps
  created_at:        Time
  updated_at:        Time
```

### Conversation states

- `:active` -- conversation is open, can receive new messages
- `:completed` -- conversation explicitly closed by user or system
- `:archived` -- conversation moved to cold storage (still retrievable)

### Conversation forking

```ruby
# Fork at message seq 15 of conversation abc-123
Legion::LLM.chat(
  conversation_id: "new-fork-uuid",
  messages: [{ role: :user, content: "Let's try a different approach" }],
  metadata: { fork_from: "abc-123", fork_at_seq: 15 }
)
# Creates new conversation with messages 1-15 copied from parent
# parent_id: "abc-123", branch_point: 15
```

---

## Config (Generation Parameters)

Sent in `request.generation`. Provider adapters map supported parameters and ignore unsupported ones.

```
generation:
  temperature:       Float?       # 0.0 to 2.0 (all providers)
  top_p:             Float?       # 0.0 to 1.0 (all providers)
  top_k:             Integer?     # Anthropic, Gemini (ignored by OpenAI)
  seed:              Integer?     # OpenAI (ignored by others)
  frequency_penalty: Float?       # OpenAI, Azure (ignored by others)
  presence_penalty:  Float?       # OpenAI, Azure (ignored by others)
```

### Thinking / Reasoning

Sent in `request.thinking`. Separate from generation because reasoning controls are about *how deeply* the model thinks, not *how randomly* it samples.

```
thinking:
  enabled:           Boolean      # enable extended thinking / chain-of-thought
  budget_tokens:     Integer?     # max tokens for thinking (Anthropic)
  effort:            Symbol?      # :low, :medium, :high (OpenAI reasoning_effort)
```

See [Thinking & Reasoning](#thinking--reasoning) for full details and provider mapping.

### Response format

Sent in `request.response_format`:

```
response_format:
  type:              Symbol       # :text, :json, :json_schema
  schema:            Hash?        # JSON Schema when type is :json_schema
```

- `:text` -- default, free-form text response
- `:json` -- response must be valid JSON (OpenAI json_mode, others via prompt)
- `:json_schema` -- response must conform to provided schema (OpenAI structured output, others via prompt + validation)

---

## Provider Adapter Contract

Every provider LEX must implement `Legion::LLM::ProviderAdapter` including a `Translator`.

### Required methods

```
chat(request) -> Response
chat_stream(request, &block) -> Response   # yields Chunks
capabilities -> Hash
health_check -> Hash
token_estimate(messages) -> Integer
```

### Optional methods

```
embed(text) -> Array<Float>
summarize(content, opts) -> String
```

### Translator (required)

```
translate_request(Request) -> provider-native Hash
translate_response(provider-native) -> Response
translate_chunk(provider-native chunk) -> Chunk
translate_tools(Array<Tool>) -> provider-native tool format
translate_error(provider exception) -> Legion::LLM error
```

### Standard errors

Provider adapters MUST raise these, never their own exceptions:

```
Legion::LLM::AuthError              # don't retry, fix credentials
Legion::LLM::RateLimitError         # retry with backoff
Legion::LLM::ContextOverflow        # reduce context, retry
Legion::LLM::ProviderError          # transient, retry
Legion::LLM::ProviderDown           # circuit breaker, failover
Legion::LLM::UnsupportedCapability  # route elsewhere
```

### Connection pooling

Providers are long-lived connection pools, not per-request objects:

```
Provider instance: boot to shutdown (holds HTTP client, auth, config)
Request object:    per-call, ephemeral (holds messages, tools, params)
Conversation:      persistent, outlives everything (in ConversationStore)

ProviderRegistry
  :claude   -> Lex::Claude::Provider   (pool_size: 10)
  :ollama   -> Lex::Ollama::Provider   (pool_size: 5)
  :bedrock  -> Lex::Bedrock::Provider  (pool_size: 10)
  :openai   -> Lex::OpenAI::Provider   (pool_size: 10)
  :gemini   -> Lex::Gemini::Provider   (pool_size: 10)
  :azure_ai -> Lex::AzureAi::Provider (pool_size: 10)
  :xai      -> Lex::Xai::Provider     (pool_size: 5)
```

---

## Provider Format Comparison

Reference examples in `docs/examples/` directory:

```
openai_request.json      openai_response.json
anthropic_request.json   anthropic_response.json
bedrock_request.json     bedrock_response.json
gemini_request.json      gemini_response.json
azure_ai_request.json    azure_ai_response.json
xai_request.json         xai_response.json
```

### Key differences handled by translators

| Aspect | OpenAI/xAI/Azure AI | Anthropic | Bedrock | Gemini |
|--------|---------------------|-----------|---------|--------|
| System msg | In messages array | Separate field | Separate field | Separate field |
| Assistant role | `"assistant"` | `"assistant"` | `"assistant"` | `"model"` |
| Content format | String or blocks | String or blocks | Always blocks | Always parts |
| Tool definition | `{type: "function", function: {}}` | `{name, input_schema}` | `{toolSpec: {inputSchema: {json}}}` | `{functionDeclarations: []}` |
| Tool call | `tool_calls` array | Content block `tool_use` | Content block `toolUse` | Part `functionCall` |
| Tool result | `role: "tool"` | Content block `tool_result` in user msg | Content block `toolResult` in user msg | Part `functionResponse` in user msg |
| Stop reason | `"stop"/"tool_calls"` | `"end_turn"/"tool_use"` | `"end_turn"/"tool_use"` | `"STOP"` |
| Token usage | `prompt_tokens/completion_tokens` | `input_tokens/output_tokens` | `input_tokens/output_tokens` | `promptTokenCount/candidatesTokenCount` |
| Image input | `image_url` block | `image` block with source | `image` block with bytes | `inlineData` part |

Legion's internal format uses:
- System: **separate** (3/4 providers do this, cleaner, no scanning messages array)
- Role: **`:assistant`** (3/4 providers)
- Content: **String shorthand with block superset** (simple text is string, multimodal is blocks)
- Collection: **`messages`** (3/4 providers)
- Tokens: **`input`/`output`/`total`** (neutral naming)

---

## Full Example

### Request

```json
{
  "id": "req_abc123",
  "conversation_id": "conv_xyz789",
  "schema_version": "1.0.0",
  "system": "You are a helpful coding assistant.",
  "messages": [
    {
      "id": "msg_001",
      "role": "user",
      "content": "What files are in the current directory?",
      "status": "created",
      "version": 1,
      "timestamp": "2026-03-23T10:00:00Z",
      "seq": 1
    }
  ],
  "tools": [
    {
      "name": "list_files",
      "description": "List files in a directory",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string" }
        },
        "required": ["path"]
      },
      "source": { "type": "mcp", "server": "filesystem" }
    }
  ],
  "tool_choice": { "mode": "auto" },
  "routing": { "provider": null, "model": null },
  "tokens": { "max": 4096 },
  "stop": { "sequences": [] },
  "generation": { "temperature": 0.7 },
  "thinking": null,
  "response_format": { "type": "text" },
  "stream": false,
  "context_strategy": "auto",
  "cache": {
    "strategy": "default",
    "ttl": 300,
    "key": null,
    "tier": "any",
    "cacheable": true
  },
  "priority": "normal",
  "metadata": { "session": "sess_abc" },
  "enrichments": {},
  "predictions": {
    "router:tool_usage": {
      "expected": true,
      "confidence": 0.85,
      "basis": "message contains 'what files'"
    },
    "context:token_estimate": {
      "expected": 300,
      "confidence": 0.9,
      "basis": "1 message, short prompt"
    }
  },
  "tracing": {
    "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
    "span_id": "00f067aa0ba902b7",
    "parent_span_id": null,
    "correlation_id": null,
    "baggage": {}
  },
  "classification": {
    "level": "internal",
    "contains_pii": false,
    "contains_phi": false,
    "jurisdictions": ["us"],
    "retention": "default",
    "consent": null
  },
  "caller": {
    "requested_by": {
      "identity": "user:matt",
      "type": "user",
      "credential": "session",
      "name": "Matt"
    },
    "requested_for": null
  },
  "agent": null,
  "billing": {
    "cost_center": "engineering-platform",
    "budget_id": "budget_q1_2026",
    "rate_limit_key": "user:matt",
    "spending_cap": 1.00
  },
  "test": null,
  "modality": {
    "input": ["text"],
    "output": ["text"],
    "preferences": null
  },
  "hooks": {
    "after_response": ["log_to_splunk"],
    "on_error": ["log_to_splunk"]
  }
}
```

### Response

```json
{
  "id": "resp_def456",
  "request_id": "req_abc123",
  "conversation_id": "conv_xyz789",
  "schema_version": "1.0.0",
  "message": {
    "id": "msg_002",
    "parent_id": "msg_001",
    "role": "assistant",
    "content": "The current directory contains README.md, src/, and lib/.",
    "status": "created",
    "version": 1,
    "timestamp": "2026-03-23T10:00:02Z",
    "seq": 2,
    "provider": "claude",
    "model": "claude-opus-4-6-20250415",
    "input_tokens": 245,
    "output_tokens": 18
  },
  "routing": {
    "provider": "claude",
    "model": "claude-opus-4-6-20250415",
    "strategy": "smart",
    "reason": "tool use requested, routed to high-capability provider",
    "escalated": false,
    "latency_ms": 1823,
    "connection": {
      "pool_id": "claude_pool",
      "reused": true,
      "tls_version": "TLSv1.3",
      "endpoint": "https://api.anthropic.com/v1/messages",
      "connect_ms": 0
    }
  },
  "tokens": {
    "max": 4096,
    "input": 245,
    "output": 18,
    "total": 263,
    "context_window": 200000,
    "utilization": 0.001315,
    "headroom": 199737
  },
  "thinking": null,
  "stop": {
    "reason": "end_turn",
    "sequence": null
  },
  "tools": [
    {
      "id": "call_abc",
      "exchange_id": "exch_001",
      "name": "list_files",
      "arguments": { "path": "." },
      "source": { "type": "mcp", "server": "filesystem" },
      "status": "success",
      "duration_ms": 45,
      "result": "[\"README.md\", \"src/\", \"lib/\"]"
    }
  ],
  "stream": false,
  "cache": {
    "hit": false,
    "key": "sha256:e3b0c44298fc1c149afb",
    "tier": null,
    "age": null,
    "expires_in": null,
    "stored_at": null
  },
  "retry": null,
  "timestamps": {
    "received": "2026-03-23T10:00:00.100Z",
    "provider_start": "2026-03-23T10:00:00.250Z",
    "provider_end": "2026-03-23T10:00:01.900Z",
    "returned": "2026-03-23T10:00:02.050Z"
  },
  "cost": {
    "estimated_usd": 0.0042,
    "provider": "claude",
    "model": "claude-opus-4-6-20250415"
  },
  "validation": null,
  "safety": null,
  "rate_limit": {
    "requests": { "remaining": 58, "limit": 60, "reset_at": "2026-03-23T10:01:00Z" },
    "tokens": { "remaining": 195000, "limit": 200000, "reset_at": "2026-03-23T10:01:00Z" }
  },
  "features": {
    "prompt_caching": { "hit": false, "tokens_saved": 0 }
  },
  "deprecation": null,
  "enrichments": {
    "rag:context_retrieval": {
      "content": "new conversation, no history to retrieve",
      "duration_ms": 1,
      "timestamp": "2026-03-23T10:00:00.110Z"
    },
    "mcp:tool_registration": {
      "content": "1 tool from filesystem server",
      "duration_ms": 5,
      "timestamp": "2026-03-23T10:00:00.115Z"
    }
  },
  "predictions": {
    "router:tool_usage": {
      "expected": true,
      "confidence": 0.85,
      "basis": "message contains 'what files'",
      "actual": true,
      "correct": true
    },
    "context:token_estimate": {
      "expected": 300,
      "confidence": 0.9,
      "basis": "1 message, short prompt",
      "actual": 263,
      "correct": true,
      "variance": 0.123
    }
  },
  "audit": {
    "rbac:permission_check": {
      "outcome": "success",
      "detail": "caller user:matt permitted for LLM access",
      "duration_ms": 2,
      "timestamp": "2026-03-23T10:00:00.105Z"
    },
    "classification:scan": {
      "outcome": "success",
      "detail": "caller declared :internal, no upgrade needed",
      "data": { "declared": "internal", "effective": "internal", "upgraded": false },
      "duration_ms": 3,
      "timestamp": "2026-03-23T10:00:00.108Z"
    },
    "billing:budget_check": {
      "outcome": "success",
      "detail": "budget check passed, $4.23 of $100.00 remaining",
      "data": { "remaining_usd": 95.77 },
      "duration_ms": 2,
      "timestamp": "2026-03-23T10:00:00.110Z"
    },
    "routing:provider_selection": {
      "outcome": "success",
      "detail": "selected claude via smart strategy: tool use capability required",
      "data": { "strategy": "smart", "candidates": 3 },
      "duration_ms": 5,
      "timestamp": "2026-03-23T10:00:00.115Z"
    },
    "persistence:store": {
      "outcome": "success",
      "detail": "conversation stored, 2 messages",
      "data": { "method": "direct", "store": "postgresql" },
      "duration_ms": 12,
      "timestamp": "2026-03-23T10:00:02.040Z"
    },
    "transport:audit_publish": {
      "outcome": "success",
      "detail": "audit event published to llm.audit exchange",
      "duration_ms": 3,
      "timestamp": "2026-03-23T10:00:02.043Z"
    }
  },
  "tracing": {
    "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
    "span_id": "00f067aa0ba902b7",
    "parent_span_id": null,
    "correlation_id": null,
    "baggage": {}
  },
  "caller": {
    "requested_by": {
      "identity": "user:matt",
      "type": "user",
      "credential": "session",
      "name": "Matt"
    },
    "requested_for": null
  },
  "classification": {
    "level": "internal",
    "contains_pii": false,
    "contains_phi": false,
    "jurisdictions": ["us"],
    "retention": "default"
  },
  "agent": null,
  "billing": {
    "cost_center": "engineering-platform",
    "budget_id": "budget_q1_2026",
    "rate_limit_key": "user:matt",
    "spending_cap": 1.00
  },
  "test": null,
  "timeline": [
    { "seq": 1, "timestamp": "2026-03-23T10:00:00.101Z", "category": "internal",
      "key": "uuid:resolve", "direction": "internal",
      "from": "pipeline", "to": "conversation_store",
      "detail": "new conversation conv_xyz789 created" },
    { "seq": 2, "timestamp": "2026-03-23T10:00:00.105Z", "category": "audit",
      "key": "rbac:permission_check", "direction": "internal",
      "from": "pipeline", "to": "rbac",
      "detail": "caller user:matt permitted", "duration_ms": 2 },
    { "seq": 3, "timestamp": "2026-03-23T10:00:00.108Z", "category": "audit",
      "key": "classification:scan", "direction": "internal",
      "from": "pipeline", "to": "classification",
      "detail": "no upgrade needed", "duration_ms": 3 },
    { "seq": 4, "timestamp": "2026-03-23T10:00:00.110Z", "category": "enrichment",
      "key": "rag:context_retrieval", "direction": "outbound",
      "from": "pipeline", "to": "apollo",
      "detail": "new conversation, no history to retrieve", "duration_ms": 1 },
    { "seq": 5, "timestamp": "2026-03-23T10:00:00.115Z", "category": "enrichment",
      "key": "mcp:tool_registration", "direction": "outbound",
      "from": "pipeline", "to": "mcp:filesystem",
      "detail": "1 tool from filesystem server", "duration_ms": 5 },
    { "seq": 6, "timestamp": "2026-03-23T10:00:00.120Z", "category": "audit",
      "key": "routing:provider_selection", "direction": "internal",
      "from": "router", "to": "pipeline",
      "detail": "selected claude via smart strategy", "duration_ms": 5 },
    { "seq": 7, "timestamp": "2026-03-23T10:00:00.250Z", "category": "provider",
      "exchange_id": "exch_001",
      "key": "provider:request_sent", "direction": "outbound",
      "from": "pipeline", "to": "provider:claude",
      "detail": "POST https://api.anthropic.com/v1/messages" },
    { "seq": 8, "timestamp": "2026-03-23T10:00:01.900Z", "category": "provider",
      "exchange_id": "exch_001",
      "key": "provider:response_received", "direction": "inbound",
      "from": "provider:claude", "to": "pipeline",
      "detail": "200 OK, tool_use, 1 tool call", "duration_ms": 1650 },
    { "seq": 9, "timestamp": "2026-03-23T10:00:01.910Z", "category": "tool",
      "exchange_id": "exch_002",
      "key": "tool:list_files:execute", "direction": "outbound",
      "from": "pipeline", "to": "mcp:filesystem",
      "detail": "executing list_files({path: '.'})", "duration_ms": 45 },
    { "seq": 10, "timestamp": "2026-03-23T10:00:01.955Z", "category": "tool",
      "exchange_id": "exch_002",
      "key": "tool:list_files:result", "direction": "inbound",
      "from": "mcp:filesystem", "to": "pipeline",
      "detail": "tool returned 3 results" },
    { "seq": 11, "timestamp": "2026-03-23T10:00:02.040Z", "category": "audit",
      "key": "persistence:store", "direction": "outbound",
      "from": "pipeline", "to": "postgresql",
      "detail": "conversation stored, 2 messages", "duration_ms": 12 },
    { "seq": 12, "timestamp": "2026-03-23T10:00:02.043Z", "category": "audit",
      "key": "transport:audit_publish", "direction": "outbound",
      "from": "pipeline", "to": "rmq:llm.audit",
      "detail": "audit event published", "duration_ms": 3 }
  ],
  "participants": [
    "pipeline", "conversation_store", "rbac", "classification", "apollo",
    "mcp:filesystem", "router", "provider:claude", "postgresql", "rmq:llm.audit"
  ],
  "warnings": [],
  "wire": null
}
```

### Error Response

```json
{
  "id": "err_ghi789",
  "request_id": "req_abc123",
  "conversation_id": "conv_xyz789",
  "schema_version": "1.0.0",
  "error": "rate_limit",
  "message": "Provider rate limited: claude (429 Too Many Requests)",
  "provider": "claude",
  "retryable": true,
  "retry_after": 30,
  "enrichments": {},
  "audit": {
    "rbac:permission_check": {
      "outcome": "success",
      "detail": "caller user:matt permitted",
      "duration_ms": 2,
      "timestamp": "2026-03-23T10:00:00.105Z"
    },
    "routing:provider_selection": {
      "outcome": "failure",
      "detail": "claude rate limited, attempted failover to openai, also rate limited",
      "data": { "attempted": ["claude", "openai"], "all_rate_limited": true },
      "duration_ms": 1200,
      "timestamp": "2026-03-23T10:00:01.500Z"
    }
  },
  "tracing": {
    "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
    "span_id": "00f067aa0ba902b7",
    "parent_span_id": null,
    "correlation_id": null
  },
  "timestamps": {
    "received": "2026-03-23T10:00:00.100Z",
    "failed": "2026-03-23T10:00:02.700Z"
  }
}
```
