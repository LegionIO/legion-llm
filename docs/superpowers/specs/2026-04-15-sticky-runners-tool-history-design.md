# Design: Sticky Runner Tool Injection + Tool Call History

**Date**: 2026-04-15
**Repo**: legion-llm + LegionIO (cross-gem)
**Status**: Approved for implementation — post adversarial review round 1

---

## Problem

When the LLM calls a tool (e.g. `list_issues`), the runner that provided it (`github_issues`) only stays injected for that one turn. On the next turn, trigger matching starts fresh — if the user's follow-up message doesn't contain the right keyword, the runner isn't re-injected and the LLM can't call `create_issue` or `update_issue`. It falls back to `legion_do` or hallucinates.

Additionally, the LLM has no memory of what tools did in prior turns of the same conversation. It can't reference "the issue I created 2 turns ago was #142" without that context being explicitly provided.

---

## Solution Overview

Two coupled features stored in a dedicated per-conversation state slot in `ConversationStore` and surfaced on every subsequent pipeline turn:

1. **Sticky runner injection** — runners stay in the injected toolset for N turns (trigger tier) or N deferred tool executions (execution tier) after activity, with window reset on re-trigger or re-execution. Never shortens.

2. **Tool call history** — every tool call (name, sanitized args, summarized result, message turn) is appended to a per-conversation list. Injected into the system prompt as a structured enrichment block on subsequent turns so the LLM can reference prior results.

---

## Storage Model

**Not** stored via `store_metadata` / `read_metadata` (which appends new messages and reads only the last one — wrong semantics for frequently-mutated structured state). Instead, a dedicated `sticky_state` slot on the conversation hash:

```ruby
conversations[conv_id][:sticky_state] = {
  sticky_runners: { ... },
  deferred_tool_calls: 7,
  tool_call_history: [ ... ]
}
```

`ConversationStore` gets two new class methods:

```ruby
def read_sticky_state(conversation_id)
  ensure_conversation(conversation_id)
  conversations[conversation_id][:sticky_state] ||= {}
end

def write_sticky_state(conversation_id, state)
  ensure_conversation(conversation_id)
  conversations[conversation_id][:sticky_state] = state
  touch(conversation_id)
end
```

Both are in-memory only (no DB persistence in this iteration — DB persistence follows the existing `persist_message` pattern and is deferred to a follow-up). All callers use symbol keys throughout — `read_metadata` uses `symbolize_names: true` and `sticky_state` is a Ruby hash, so symbols are natural.

---

## Data Model

### `sticky_runners`

```ruby
{
  sticky_runners: {
    "github_issues" => { expires_after_deferred_call: 12, tier: :executed },
    "github_branches" => { expires_at_turn: 5, tier: :triggered }
  },
  deferred_tool_calls: 7
}
```

- **Key**: `"#{tool_class.extension}_#{tool_class.runner}"` using underscores throughout — exact values produced by `derive_extension_name` and `derive_runner_snake` in `Tools::Discovery`
- **`expires_after_deferred_call`**: execution-tier only — runner expires when `deferred_tool_calls >= this value`
- **`expires_at_turn`**: trigger-tier only — runner expires when message count exceeds this value
- **`deferred_tool_calls`**: counter of deferred/triggered tool executions only — always-loaded tools (`legion_do`, `legion_status`, etc.) do NOT increment this counter. The clock is "work in progress with specialized runners", not total tool activity
- **`tier`**: `:triggered` or `:executed`

### `tool_call_history`

```ruby
{
  tool_call_history: [
    {
      tool: "legion-github-issues-list_issues",
      runner: "github_issues",
      turn: 3,                          # message count at time of call — human-readable "Turn N"
      args: { owner: "LegionIO", repo: "legion-mcp", state: "open" },
      result: '{"result":[{"number":42,"title":"Fix pipeline bug"},...]}'  ,
      error: false
    }
  ]
}
```

- `turn` — `ConversationStore.messages(conv_id).size` at time of call. Human-readable message-turn label for the history enrichment. Separate from `deferred_tool_calls` clock
- `result` — truncated to `max_result_length` chars
- `args` — sanitized: known sensitive param names redacted before storage (see Arg Sanitization below)
- `error: true` when the tool returned an error response

---

## Sticky Window Tiers

Two independent clocks — trigger stickiness counts message turns, execution stickiness counts deferred tool calls:

| Event | Clock | Window | Expiry stored as |
|-------|-------|--------|-----------------|
| Trigger word matched for runner | Message turns | `trigger_sticky_turns` (default: 2) | `expires_at_turn = current_message_count + 2` |
| Deferred tool from runner executed | Deferred tool call count | `execution_sticky_tool_calls` (default: 5) | `expires_after_deferred_call = deferred_tool_calls + 5` |
| Re-trigger while triggered-sticky | Message turns | `max(current_expiry, current_message_count + trigger_window)` | Never shortens |
| Re-execution while sticky (any tier) | Deferred call count | `max(current_expiry, deferred_tool_calls + execution_window)`, upgrade tier to `:executed` | Always upgrades |
| Trigger fires on currently execution-sticky runner | — | No-op — guard: `only if not already execution-sticky` in persist logic | Execution window preserved |
| Trigger fires on EXPIRED execution-sticky runner | Message turns | Treat as fresh trigger — set tier `:triggered`, `expires_at_turn = current + trigger_window` | Re-activates under trigger tier |

**Why two clocks?** Trigger stickiness fades after a couple of exchanges if the user moves on. Execution stickiness is work-in-progress — deliberating over 10 messages before creating a second issue keeps the runner available.

**Why deferred-only counter?** Always-loaded tools (`legion_do`, `legion_status`) firing repeatedly should not drain the sticky window for specialized runners. The counter represents "work done with specific runners", not total tool activity.

---

## Pipeline Changes

### Repos modified

**legion-llm**: new step files, executor changes, enrichment injector, conversation store
**LegionIO**: `Tools::Base` (sticky accessor), `Tools::Discovery` (set sticky on tool class), `Extensions::Core` (sticky_tools? default)

### Snapshot ivar

At the start of `step_sticky_runners`, capture `@sticky_turn_snapshot = ConversationStore.messages(conv_id).size`. Both the step and the persist methods use this same value — avoids one-off errors from message count changing mid-turn as `step_context_store` appends messages.

### `step_context_store` timing

`@raw_response.tool_calls` IS available at `step_context_store` time — it's on `@raw_response` which is set by `execute_provider_request` before `step_context_store` runs. The `response_tool_calls` private method (executor.rb:1093) reads from `@raw_response` — this is fine since `@raw_response` is set. What is NOT available is the formatted `response_tool_calls` array from `build_response` — but `step_context_store` can call `response_tool_calls` directly (it's on self). However, to be safe and capture streaming tool calls too (see Streaming below), tool call data is accumulated in `@pending_tool_history` during `step_tool_calls` (which runs before `step_context_store`).

---

#### 1. New: `lib/legion/llm/pipeline/steps/sticky_runners.rb`

Module `Steps::StickyRunners` included in `Executor`.

**`step_sticky_runners`** (pre-provider, between `trigger_match` and `tool_discovery`):
- Return immediately if `!sticky_enabled? || !conv_id`
- Capture `@sticky_turn_snapshot = ConversationStore.messages(conv_id).size`
- Read state: `state = ConversationStore.read_sticky_state(conv_id)`
- Filter live runners:
  - triggered: `expires_at_turn > @sticky_turn_snapshot`
  - executed: `expires_after_deferred_call > (state[:deferred_tool_calls] || 0)`
  - expired execution-tier entries are removed and not treated as active
- For each live runner key, find all deferred tools in `Registry` where `"#{tool_class.extension}_#{tool_class.runner}" == key` and `tool_class.sticky != false`
- Merge into `@triggered_tools` (deduplicating)
- Record in `@enrichments['tool:sticky_runners']` for timeline

**`persist_sticky_runners`** (called from `step_context_store`):
- Return immediately if `!sticky_enabled? || !conv_id`
- Read current state atomically: `state = ConversationStore.read_sticky_state(conv_id)`
- Determine executed runners: look up each tool in `@pending_tool_history` by name in Registry → get `extension_runner` key. Only count deferred tools (skip tools where `tool_class.deferred? == false`)
- Increment `state[:deferred_tool_calls]` by number of deferred tools executed
- For each executed deferred runner key: `expires_after_deferred_call = max(existing, deferred_tool_calls + execution_sticky_tool_calls)`, tier `:executed`
- For each trigger-matched runner (in `@triggered_tools` keys minus executed): apply trigger window ONLY if not currently execution-sticky
- For expired execution-sticky runners that were re-triggered: set tier `:triggered`, `expires_at_turn`
- Write back: `ConversationStore.write_sticky_state(conv_id, state)`

---

#### 2. New: `lib/legion/llm/pipeline/steps/tool_history.rb`

Module `Steps::ToolHistory` included in `Executor`.

**`step_tool_history_inject`** (pre-provider, between `sticky_runners` and `tool_discovery`):
- Return immediately if `!sticky_enabled? || !conv_id`
- Read: `state = ConversationStore.read_sticky_state(conv_id)`
- If `state[:tool_call_history]` is non-empty, build formatted enrichment string → `@enrichments['tool:call_history']`
- Format:
  ```
  Tools used in this conversation:
  - Turn 3: list_issues(owner: LegionIO, repo: legion-mcp, state: open) → 5 open issues returned
  - Turn 4: create_issue(owner: LegionIO, repo: legion-mcp, title: Add sticky tools) → issue #43 created
  ```

**`step_tool_history_persist`** (post-provider, new step added to `POST_PROVIDER_STEPS`, after `metering`, before `context_store`):
- Return immediately if `!sticky_enabled? || !conv_id`
- Build records from `@pending_tool_history` (accumulated during `step_tool_calls` and streaming callbacks)
- Each record: sanitize args (see Arg Sanitization), truncate result to `max_result_length`, set `turn: @sticky_turn_snapshot`, `error:` from result content
- Read state, append records, trim to `max_history_entries`, write back

**`@pending_tool_history`** accumulator (ivar on Executor, initialized to `[]`):
- `step_tool_calls` and `emit_tool_result_event` (streaming) append raw `{ tool_name:, args:, result:, error: }` hashes
- `step_tool_history_persist` reads and clears it

---

#### 3. `lib/legion/llm/pipeline/executor.rb`

- Include `Steps::StickyRunners` and `Steps::ToolHistory`
- Initialize `@pending_tool_history = []` in `initialize`
- Add `step_sticky_runners` and `step_tool_history_inject` to `STEPS` and `PRE_PROVIDER_STEPS` (between `trigger_match` and `tool_discovery`)
- Add `step_tool_history_persist` to `STEPS` and `POST_PROVIDER_STEPS` (after `metering`)
- `step_context_store` calls `persist_sticky_runners`

---

#### 4. `lib/legion/llm/pipeline/profile.rb`

Add to skip lists:
- `GAIA_SKIP`, `SYSTEM_SKIP`, `QUICK_REPLY_SKIP`, `SERVICE_SKIP`: add `:sticky_runners`, `:tool_history_inject`, `:tool_history_persist`

---

#### 5. `lib/legion/llm/pipeline/enrichment_injector.rb`

Add handling for `'tool:call_history'` enrichment key (after RAG context, before skill injection):

```ruby
if (history = enrichments['tool:call_history'])
  parts << history
end
```

The value is a pre-formatted string written by `step_tool_history_inject`. Consistent with the `skill:active` enrichment which also stores a pre-formatted string.

---

#### 6. `lib/legion/llm/conversation_store.rb`

Add two new class methods:

```ruby
def read_sticky_state(conversation_id)
  ensure_conversation(conversation_id)
  conversations[conversation_id][:sticky_state] ||= {}
end

def write_sticky_state(conversation_id, state)
  ensure_conversation(conversation_id)
  conversations[conversation_id][:sticky_state] = state
  touch(conversation_id)
end
```

No changes to `store_metadata` or `read_metadata`.

---

### LegionIO changes

#### `lib/legion/tools/base.rb`

Add `sticky` accessor alongside `deferred`, `extension`, `runner`:

```ruby
def sticky(val = nil)
  return @sticky.nil? ? true : @sticky if val.nil?
  @sticky = val
end
```

Default `true` — tools are sticky unless explicitly set to `false`.

#### `lib/legion/tools/discovery.rb`

In `tool_attributes`, add:

```ruby
sticky: ext.respond_to?(:sticky_tools?) ? ext.sticky_tools? : true
```

In `create_tool_class`, add:

```ruby
sticky(attrs[:sticky])
```

#### `lib/legion/extensions/core.rb`

Add alongside `mcp_tools?`:

```ruby
def sticky_tools?
  true
end
```

Instance method — same pattern as `mcp_tools?`. `Tools::Discovery` calls `ext.respond_to?(:sticky_tools?)` where `ext` is the extension module. Since extensions `include Core` (or `extend Core`), this is reachable. Extensions that opt out define `def self.sticky_tools? false end`.

---

## Streaming Support

During streaming (`call_stream`), tool calls fire via `emit_tool_call_event` / `emit_tool_result_event` callbacks. The `@pending_tool_history` accumulator must be fed from `emit_tool_result_event`:

```ruby
def emit_tool_result_event(tool_result)
  # existing event emission ...
  @pending_tool_history << {
    tool_name: tc_name,
    args:      {},   # args captured separately via emit_tool_call_event
    result:    raw.is_a?(String) ? raw : raw.to_s,
    error:     raw.is_a?(Hash) && (raw[:error] || raw['error'])
  }
end
```

`emit_tool_call_event` also updates the args for the pending entry by tool_call_id.

---

## Arg Sanitization

Before storing args in `tool_call_history`, redact known sensitive param names:

```ruby
SENSITIVE_PARAM_NAMES = %w[api_key token secret password bearer_token access_token
                            private_key secret_key auth_token credential].freeze

def sanitize_args(args)
  args.each_with_object({}) do |(k, v), h|
    h[k] = SENSITIVE_PARAM_NAMES.include?(k.to_s.downcase) ? '[REDACTED]' : v
  end
end
```

Also truncate individual arg values to `max_args_length` (default: 500 chars).

---

## Result Summarization

A lightweight summarizer in `Steps::ToolHistory` extracts key fields for the enrichment text (not for storage — full truncated result is stored):

- If result is an array → `"N items returned"`
- If result contains `"number"` and `"html_url"` → `"#N at URL"`
- If result contains `"error"` → `"error: <message>"`
- Otherwise → first 200 chars

---

## Settings

All numeric thresholds configurable — no magic numbers in code.

```json
{
  "llm": {
    "tool_sticky": {
      "enabled": true,
      "trigger_turns": 2,
      "execution_tool_calls": 5,
      "max_history_entries": 50,
      "max_result_length": 2000,
      "max_args_length": 500
    }
  }
}
```

Settings helpers (shared mixin or module_function in both new step modules):

```ruby
def sticky_enabled?
  Legion::Settings.dig(:llm, :tool_sticky, :enabled) != false
end

def trigger_sticky_turns
  Legion::Settings.dig(:llm, :tool_sticky, :trigger_turns) || 2
end

def execution_sticky_tool_calls
  Legion::Settings.dig(:llm, :tool_sticky, :execution_tool_calls) || 5
end

def max_history_entries
  Legion::Settings.dig(:llm, :tool_sticky, :max_history_entries) || 50
end

def max_result_length
  Legion::Settings.dig(:llm, :tool_sticky, :max_result_length) || 2000
end

def max_args_length
  Legion::Settings.dig(:llm, :tool_sticky, :max_args_length) || 500
end
```

---

## Lex-Level Opt-Out

`Legion::Extensions::Core` defines `sticky_tools?` as an instance method (same pattern as `mcp_tools?`). Discovery checks `ext.respond_to?(:sticky_tools?)` where `ext` is the extension module — accessible via include. Extensions that opt out override with an explicit module method:

```ruby
# Core default (instance method, accessible on extension module via include)
def sticky_tools?
  true
end

# Extension opt-out (explicit module method)
def self.sticky_tools?
  false
end
```

Runner-level opt-out is not included — lex-level covers all realistic cases.

---

## Spec Coverage

**legion-llm**:
- `spec/legion/llm/pipeline/steps/sticky_runners_spec.rb` — step injection, window tiers, max rule, expiry filtering, persist logic, deferred-only counter, expired execution re-trigger
- `spec/legion/llm/pipeline/steps/tool_history_spec.rb` — append, truncation, summarization, enrichment format, arg sanitization, max_history_entries trim
- `spec/legion/llm/pipeline/enrichment_injector_spec.rb` — history block injection
- `spec/legion/llm/conversation_store_spec.rb` — `read_sticky_state`, `write_sticky_state`
- `spec/legion/llm/pipeline/executor_spec.rb` — `@pending_tool_history` accumulation, nil conv_id guards, profile skip

**LegionIO**:
- `spec/legion/tools/base_spec.rb` — `sticky` accessor default true
- `spec/legion/tools/discovery_spec.rb` — `sticky` attribute set from `sticky_tools?`
- `spec/legion/extensions/core_spec.rb` — `sticky_tools?` default

---

## Not Included

- Per-runner stickiness opt-out (lex-level only)
- Compounding sticky windows (max rule only)
- DB-backed sticky state / tool history (in-memory only — DB persistence deferred)
- UI changes to legion-interlink for displaying tool history
- Encryption of tool call history (deferred — consistent with unencrypted ConversationStore messages)
