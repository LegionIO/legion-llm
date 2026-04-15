# Design: Sticky Runner Tool Injection + Tool Call History

**Date**: 2026-04-15
**Repo**: legion-llm + LegionIO (cross-gem)
**Status**: Approved for implementation — post adversarial review rounds 1 + 2 + 3

---

## Problem

When the LLM calls a tool (e.g. `list_issues`), the runner that provided it (`github_issues`) only stays injected for that one turn. On the next turn, trigger matching starts fresh — if the user's follow-up message doesn't contain the right keyword, the runner isn't re-injected and the LLM can't call `create_issue` or `update_issue`. It falls back to `legion_do` or hallucinates.

Additionally, the LLM has no memory of what tools did in prior turns of the same conversation. It can't reference "the issue I created 2 turns ago was #142" without that context being explicitly provided.

---

## Solution Overview

Two coupled features stored in a dedicated per-conversation state slot in `ConversationStore` and surfaced on every subsequent pipeline turn:

1. **Sticky runner injection** — runners stay in the injected toolset for N human turns (trigger tier) or N deferred tool executions (execution tier) after activity. Window resets on re-trigger or re-execution; never shortens.

2. **Tool call history** — every tool call (name, sanitized args, summarized result, human turn) is appended to a per-conversation list. Injected into the system prompt as a structured enrichment block on subsequent turns so the LLM can reference prior results.

---

## Storage Model

Not stored via `store_metadata` / `read_metadata` (append-only with read-latest semantics — wrong for frequently-mutated structured state). Instead, a dedicated `sticky_state` slot on the conversation hash:

```ruby
conversations[conv_id][:sticky_state] = {
  sticky_runners:    { ... },
  deferred_tool_calls: 7,
  tool_call_history: [ ... ]
}
```

### New ConversationStore methods

```ruby
# Returns {} (frozen) if conversation not in memory — does NOT call ensure_conversation.
# Sticky state is in-memory only; if the conversation was evicted, state is already gone.
def read_sticky_state(conversation_id)
  return {}.freeze unless in_memory?(conversation_id)
  conversations[conversation_id][:sticky_state] ||= {}
end

# Writes state. Only writes if conversation is already in memory.
# If the conversation was evicted, sticky state is already lost — do not resurrect an
# empty shell that would clobber DB-loaded message history on the next step_context_load.
def write_sticky_state(conversation_id, state)
  return unless in_memory?(conversation_id)
  conversations[conversation_id][:sticky_state] = state
  touch(conversation_id)
end
```

`read_sticky_state` returns the live hash (not a dup). Callers MUST treat it as read-only and call `write_sticky_state` with a modified copy to persist changes.

**LRU eviction**: When `evict_if_needed` evicts a conversation that has a non-empty `sticky_state`, a warning is logged. Sticky state is in-memory only — no DB persistence in this iteration. Known limitation: if a conversation is evicted (MAX_CONVERSATIONS=256 reached) and then resumed, sticky state is silently lost.

**DB persistence**: Deferred to a follow-up — follows the existing `persist_message` pattern.

---

## Data Model

All keys are Ruby symbols throughout (consistent with `symbolize_names: true` used elsewhere in ConversationStore).

### `sticky_runners`

```ruby
{
  sticky_runners: {
    "github_issues"  => { expires_after_deferred_call: 12, tier: :executed },
    "github_branches" => { expires_at_turn: 5, tier: :triggered }
  },
  deferred_tool_calls: 7
}
```

- **Key**: `"#{tool_class.extension}_#{tool_class.runner}"` — underscores throughout, matching exact output of `derive_extension_name` and `derive_runner_snake` in `Tools::Discovery`
- **`expires_after_deferred_call`**: execution-tier only — runner expires when `deferred_tool_calls >= this value`
- **`expires_at_turn`**: trigger-tier only — runner expires when human turn count `>= this value`
- **`deferred_tool_calls`**: count of individual deferred tool executions (not unique runners). Incremented by the number of deferred tools that completed successfully this turn. Always-loaded tools do NOT increment this counter.
- **`tier`**: `:triggered` or `:executed`

### `tool_call_history`

```ruby
{
  tool_call_history: [
    {
      tool:   "legion-github-issues-list_issues",
      runner: "github_issues",
      turn:   3,
      args:   { owner: "LegionIO", repo: "legion-mcp", state: "open" },
      result: '{"result":[{"number":42,"title":"Fix pipeline bug"},...]}',
      error:  false
    }
  ]
}
```

- `turn` — human turn count (`@sticky_turn_snapshot`) at call time
- `result` — truncated to `max_result_length` chars
- `args` — sanitized and truncated before storage (see Arg Sanitization)
- `error: true` when tool returned an error response

---

## Sticky Window Tiers

Two independent clocks — trigger stickiness counts human turns (user messages), execution stickiness counts individual deferred tool executions:

| Event | Clock | Window | Expiry stored as |
|-------|-------|--------|-----------------|
| Trigger word matched for runner | Human turns | `trigger_sticky_turns` (default: 2) | `expires_at_turn = snapshot + 2` |
| Deferred tool from runner executed | Deferred tool call count | `execution_sticky_tool_calls` (default: 5) | `expires_after_deferred_call = deferred_tool_calls + 5` |
| Re-trigger while triggered-sticky | Human turns | `max(current_expiry, snapshot + trigger_window)` | Never shortens |
| Re-execution while sticky (any tier) | Deferred call count | `max(current_expiry, deferred_tool_calls + execution_window)`, upgrade tier to `:executed` | Always upgrades |
| Trigger fires on currently execution-sticky runner | — | No-op — guard in persist: only apply trigger window if not already execution-sticky | Execution window preserved |
| Trigger fires on EXPIRED execution-sticky runner | Human turns | Fresh trigger — tier `:triggered`, `expires_at_turn = snapshot + trigger_window` | Re-activates under trigger tier |

Expiry comparison is strict `<` on the live side: a runner is live while `snapshot < expires_at_turn` or `deferred_tool_calls < expires_after_deferred_call`. It expires the first turn/call where that comparison becomes false.

**Why human turn count, not raw message count?** Each human turn adds at least 2 raw messages (user + assistant). Using `ConversationStore.messages.size` as the clock would make `trigger_sticky_turns=2` expire after approximately 1 human interaction, not 2. The snapshot counts only user-role messages to track actual human turns.

**Why deferred-only counter?** Always-loaded tools (`legion_do`, `legion_status`) firing repeatedly should not drain the sticky window for specialized runners.

---

## Pipeline Changes

### Repos modified

- **legion-llm**: new step files, executor changes, conversation store methods, enrichment injector
- **LegionIO**: `Tools::Base` (sticky accessor), `Tools::Discovery` (set sticky on tool class, specify Registry bucket), `Extensions::Core` (sticky_tools? default)

**Release ordering**: LegionIO changes MUST be released before or simultaneously with legion-llm changes. `step_sticky_runners` guards all `tool_class.sticky` calls with `tool_class.respond_to?(:sticky)` to handle partial deployment safely.

### `@sticky_turn_snapshot` ivar

Initialized to `nil` in `Executor#initialize`. Set at the start of `step_sticky_runners`:

```ruby
@sticky_turn_snapshot = ConversationStore.messages(conv_id)
                          .count { |m| (m[:role] || m['role']).to_s == 'user' }
```

Counts only user-role messages so 1 unit = 1 human turn. Both step and persist use this same snapshot.

`step_sticky_runners_persist` checks `return unless @sticky_turn_snapshot` — no-op if pre-provider step was profile-skipped.

### `@pending_tool_history` ivar

Initialized to `[]` in `Executor#initialize`. Populated by two sources:

1. **`emit_tool_call_event` / `emit_tool_result_event` callbacks** — for tools dispatched natively by RubyLLM via `session.ask` (covers both streaming and non-streaming RubyLLM paths)
2. **`step_tool_calls`** — for tools dispatched via `ToolDispatcher` (MCP tools, extension overrides) which do NOT trigger the RubyLLM `on_tool_call`/`on_tool_result` callbacks

These are mutually exclusive paths — no double-population risk.

### `@injected_tool_map` ivar

Initialized to `{}` in `Executor#initialize`. Built during `inject_registry_tools`:

```ruby
adapter = ToolAdapter.new(tool_class)
@injected_tool_map[adapter.name] = tool_class  # sanitized name → tool class
session.with_tool(adapter)
```

Used by both persist steps to look up tool classes by the sanitized name the LLM echoes back. Avoids the `Registry.find` mismatch caused by `sanitize_tool_name` (64-char truncation, dot→underscore conversion).

### `@freshly_triggered_keys` ivar

Initialized to `[]` in `Executor#initialize`. Set after `step_trigger_match` completes, BEFORE `step_sticky_runners` runs:

```ruby
@freshly_triggered_keys = @triggered_tools.map { |t| "#{t.extension}_#{t.runner}" }.uniq
```

`step_sticky_runners_persist` uses `@freshly_triggered_keys` (not all of `@triggered_tools`) for trigger-tier window updates. This prevents re-injected sticky runners from refreshing their own trigger windows every turn and making trigger stickiness self-perpetuating.

---

#### 1. New: `lib/legion/llm/pipeline/steps/sticky_runners.rb`

Module `Steps::StickyRunners` included in `Executor`. Three methods:

**`step_sticky_runners`** (pre-provider, after `trigger_match`):
```
return unless sticky_enabled? && conv_id

# Snapshot human turn count BEFORE this turn's messages are appended
@sticky_turn_snapshot = ConversationStore.messages(conv_id)
                          .count { |m| (m[:role] || m['role']).to_s == 'user' }

# Capture freshly triggered keys BEFORE we add sticky re-injections to @triggered_tools
@freshly_triggered_keys = @triggered_tools.map { |t| "#{t.extension}_#{t.runner}" }.uniq

state = ConversationStore.read_sticky_state(conv_id)
runners = state[:sticky_runners] || {}
deferred_count = state[:deferred_tool_calls] || 0

live_keys = runners.select { |_k, v|
  (v[:tier] == :triggered && @sticky_turn_snapshot < v[:expires_at_turn]) ||
  (v[:tier] == :executed  && deferred_count < v[:expires_after_deferred_call])
}.keys

Registry.deferred_tools.each do |tool_class|
  key = "#{tool_class.extension}_#{tool_class.runner}"
  next unless live_keys.include?(key)
  next if tool_class.respond_to?(:sticky) && tool_class.sticky == false
  next if @triggered_tools.any? { |t| t.tool_name == tool_class.tool_name }
  @triggered_tools << tool_class
end

record enrichment + timeline
```

**`step_sticky_runners_persist`** (post-provider, after `tool_calls`):
```
return unless @sticky_turn_snapshot   # skipped if pre-provider step was profile-skipped
return unless sticky_enabled? && conv_id

state = ConversationStore.read_sticky_state(conv_id).dup
runners = (state[:sticky_runners] || {}).dup
deferred_count = state[:deferred_tool_calls] || 0

# Determine which deferred tools executed successfully this turn
# Use @injected_tool_map (sanitized name → tool class) to handle name truncation
completed_entries = @pending_tool_history.select { |e| e[:result] && !e[:error] }
executed_runner_keys = []
deferred_call_count  = 0

completed_entries.each do |entry|
  tc = @injected_tool_map[entry[:tool_name]]
  next unless tc&.deferred?
  executed_runner_keys << "#{tc.extension}_#{tc.runner}"
  deferred_call_count += 1  # count individual calls, not unique runners
end

executed_runner_keys.uniq!

# Increment deferred counter by actual tool call count
deferred_count += deferred_call_count
state[:deferred_tool_calls] = deferred_count

# Update execution-tier stickiness for executed runners
executed_runner_keys.each do |key|
  existing = runners[key]
  new_expiry = deferred_count + execution_sticky_tool_calls
  runners[key] = {
    tier: :executed,
    expires_after_deferred_call: [existing&.dig(:expires_after_deferred_call) || 0, new_expiry].max
  }
end

# Update trigger-tier stickiness for FRESHLY triggered runners only
# (not re-injected sticky runners — prevents self-perpetuating windows)
(@freshly_triggered_keys - executed_runner_keys).each do |key|
  next if runners[key]&.dig(:tier) == :executed  # already execution-sticky, no-op
  existing_expiry = runners.dig(key, :expires_at_turn) || 0
  new_expiry = @sticky_turn_snapshot + trigger_sticky_turns
  runners[key] = { tier: :triggered, expires_at_turn: [existing_expiry, new_expiry].max }
end

state[:sticky_runners] = runners
ConversationStore.write_sticky_state(conv_id, state)
```

---

#### 2. New: `lib/legion/llm/pipeline/steps/tool_history.rb`

Module `Steps::ToolHistory` included in `Executor`.

**`step_tool_history_inject`** (pre-provider):
```
return unless sticky_enabled? && conv_id
state = ConversationStore.read_sticky_state(conv_id)
history = state[:tool_call_history] || []
return if history.empty?
@enrichments['tool:call_history'] = {
  content:   format_history(history),
  data:      { entry_count: history.size },
  timestamp: Time.now
}
```

Format of `format_history` output (pre-formatted string inside the `content:` key):
```
Tools used in this conversation:
- Turn 3: list_issues(owner: LegionIO, repo: legion-mcp, state: open) → 5 open issues returned
- Turn 4: create_issue(owner: LegionIO, repo: legion-mcp, title: Add sticky tools) → issue #43 created
```

**`step_tool_history_persist`** (post-provider, after `tool_calls`):
```
return unless sticky_enabled? && conv_id && @pending_tool_history.any?

state = ConversationStore.read_sticky_state(conv_id).dup
history = (state[:tool_call_history] || []).dup
turn = @sticky_turn_snapshot || 0

@pending_tool_history.each do |entry|
  next unless entry[:result]  # skip incomplete entries (tool_call without result)
  tc    = @injected_tool_map[entry[:tool_name]]  # sanitized name lookup
  runner_key = tc ? "#{tc.extension}_#{tc.runner}" : "unknown"
  history << {
    tool:   entry[:tool_name],
    runner: runner_key,
    turn:   turn,
    args:   sanitize_args(truncate_args(entry[:args] || {})),
    result: entry[:result].to_s[0, max_result_length],
    error:  entry[:error] || false
  }
end

history = history.last(max_history_entries)
state[:tool_call_history] = history
ConversationStore.write_sticky_state(conv_id, state)
```

---

#### 3. `lib/legion/llm/pipeline/executor.rb`

- Include `Steps::StickyRunners` and `Steps::ToolHistory`
- Initialize in `initialize`:
  - `@sticky_turn_snapshot = nil`
  - `@pending_tool_history = []`
  - `@injected_tool_map = {}`
  - `@freshly_triggered_keys = []`
- Update `STEPS`, `PRE_PROVIDER_STEPS`, `POST_PROVIDER_STEPS` as shown in Steps section
- Update `inject_registry_tools` to populate `@injected_tool_map`
- Update `emit_tool_call_event` to push partial entry to `@pending_tool_history`
- Update `emit_tool_result_event` to find by `tool_call_id` and fill result

**`emit_tool_call_event` changes**:
```ruby
def emit_tool_call_event(tool_call, round)
  tc_id   = tool_call_field(tool_call, :id)
  tc_name = tool_call_field(tool_call, :name)
  tc_args = tool_call_field(tool_call, :arguments) || {}

  # Record in pending history — result filled by emit_tool_result_event
  pending_index = @pending_tool_history.size
  @pending_tool_history << {
    tool_call_id:    tc_id,
    pending_index:   pending_index,
    tool_name:       tc_name,
    args:            tc_args,
    result:          nil,
    error:           false
  }

  # Store index for nil-id fallback in emit_tool_result_event
  Thread.current[:legion_current_tool_history_index] = pending_index

  # ... existing Thread.current tracking for timing/event handler ...
end
```

**`emit_tool_result_event` changes**:
```ruby
def emit_tool_result_event(tool_result)
  tc_id  = tool_result.respond_to?(:tool_call_id) ? tool_result.tool_call_id
           : Thread.current[:legion_current_tool_call_id]
  raw    = tool_result.respond_to?(:result) ? tool_result.result : tool_result

  # Find entry by tool_call_id; fall back to index for providers that omit IDs
  entry = @pending_tool_history.find { |e| e[:tool_call_id] == tc_id }
  entry ||= @pending_tool_history[Thread.current[:legion_current_tool_history_index]]

  if entry
    entry[:result] = raw.is_a?(String) ? raw : raw.to_s
    entry[:error]  = raw.is_a?(Hash) && (raw[:error] || raw['error']) ? true : false
  end

  # ... existing event emission ...
end
```

**`step_tool_calls` changes** (append to `@pending_tool_history` for ToolDispatcher path):
```ruby
# After dispatching each tool via ToolDispatcher, append to history
# These tools do NOT fire on_tool_call/on_tool_result callbacks
@pending_tool_history << {
  tool_call_id:  tool_call_id,
  pending_index: @pending_tool_history.size,
  tool_name:     tool_name,
  args:          tc[:arguments] || tc['arguments'] || {},
  result:        result_string,
  error:         result[:status] == :error
}
```

---

#### 4. `lib/legion/llm/pipeline/enrichment_injector.rb`

Add `tool:call_history` AFTER skill injection (not before):

```ruby
# After skill:active block, before appending caller system prompt:
if (history_block = enrichments.dig('tool:call_history', :content))
  parts << history_block
end
```

Order: baseline → GAIA system prompt → RAG context → skill → **tool history** → caller system prompt

Consistent with other enrichment structure: value stored as `{ content:, data:, timestamp: }`, accessed via `.dig(:content)`.

---

#### 5. `lib/legion/llm/conversation_store.rb`

Add `read_sticky_state` and `write_sticky_state` as shown in Storage Model section.

Update `evict_if_needed` to log when evicting a conversation with sticky state:
```ruby
if conversations[oldest_id]&.dig(:sticky_state)&.any?
  log&.warn("[ConversationStore] evicting #{oldest_id} with non-empty sticky_state — sticky runner and tool history state lost")
end
conversations.delete(oldest_id)
```

---

### LegionIO changes

#### `lib/legion/tools/base.rb`

Add `sticky` accessor (alongside `deferred`, `extension`, `runner`):

```ruby
def sticky(val = nil)
  return @sticky.nil? ? true : @sticky if val.nil?
  @sticky = val
end
```

Default: `true` when never set.

#### `lib/legion/tools/discovery.rb`

In `tool_attributes`, add (boolean-coerced to prevent nil promotion to true):

```ruby
sticky: !!(ext.respond_to?(:sticky_tools?) ? ext.sticky_tools? : true)
```

`nil` from `sticky_tools?` becomes `false` via `!!nil` (conservative opt-out).

In `create_tool_class`, add:

```ruby
sticky(attrs[:sticky])
```

When searching for sticky tools to re-inject, use `Registry.deferred_tools` only — always-loaded tools are already always-injected and must not appear in sticky state.

#### `lib/legion/extensions/core.rb`

Add alongside `mcp_tools?`:

```ruby
def sticky_tools?
  true
end
```

Instance method accessible on extension modules via `extend` (same mechanism as `mcp_tools?`). Extensions that opt out define `def self.sticky_tools? false end`.

---

## Arg Sanitization

```ruby
SENSITIVE_PARAM_NAMES = %w[
  api_key token secret password bearer_token
  access_token private_key secret_key auth_token credential
].freeze

def sanitize_args(args)
  args.each_with_object({}) do |(k, v), h|
    h[k] = SENSITIVE_PARAM_NAMES.include?(k.to_s.downcase) ? '[REDACTED]' : v
  end
end

def truncate_args(args)
  args.each_with_object({}) do |(k, v), h|
    h[k] = v.to_s.length > max_args_length ? "#{v.to_s[0, max_args_length]}…" : v
  end
end
```

---

## Result Summarization

Lightweight summarizer for the enrichment text (injected text only — full truncated result is stored):

- Array result → `"N items returned"`
- Result contains `"number"` and `"html_url"` → `"#N at URL"`
- `error: true` → `"error: <first 100 chars of result>"`
- Otherwise → first 200 chars

---

## Settings

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

Settings helpers shared by both new step modules:

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

`Extensions::Core` defines `sticky_tools?` as an instance method accessible via `extend` (same pattern as `mcp_tools?`). Extensions that opt out define an explicit module method:

```ruby
# Core default (instance method, accessible on extension module via extend)
def sticky_tools?
  true
end

# Extension opt-out (explicit module method, overrides extend)
def self.sticky_tools?
  false
end
```

`tool_attributes` boolean-coerces the result (`!!`) so nil returns from `sticky_tools?` are treated as opt-out (false), not opt-in.

Runner-level opt-out not included — lex-level covers all realistic cases.

---

## Spec Coverage

**legion-llm**:
- `spec/legion/llm/pipeline/steps/sticky_runners_spec.rb` — step injection, window tiers, strict `<` live check, max rule, expired execution re-trigger, deferred actual-call counter, nil snapshot guard, profile skip, `@freshly_triggered_keys` prevents window refresh for re-injected runners, `@injected_tool_map` lookup
- `spec/legion/llm/pipeline/steps/tool_history_spec.rb` — append, truncation, arg sanitization, result summarization, enrichment structure `{content:, data:, timestamp:}`, max_history_entries trim, incomplete entry skip, `step_tool_calls` path vs callback path
- `spec/legion/llm/pipeline/enrichment_injector_spec.rb` — history block injection after skill, `.dig('tool:call_history', :content)`
- `spec/legion/llm/conversation_store_spec.rb` — `read_sticky_state` returns frozen {} for unknown conv, `write_sticky_state` no-ops for unknown conv, eviction warning log
- `spec/legion/llm/pipeline/executor_spec.rb` — `@pending_tool_history` callback population, nil tool_call_id index fallback, `@injected_tool_map` population in inject_registry_tools, profile skip for all 4 new steps, `@freshly_triggered_keys` captured before sticky re-injection

**LegionIO**:
- `spec/legion/tools/base_spec.rb` — `sticky` accessor: default true, false when set, nil call is read-only
- `spec/legion/tools/discovery_spec.rb` — boolean coercion: nil → false, true → true, false → false; Registry.deferred_tools used for sticky lookup
- `spec/legion/extensions/core_spec.rb` — `sticky_tools?` default true

---

## Not Included

- Runner-level sticky opt-out (lex-level only)
- Compounding sticky windows (max rule only)
- DB-backed sticky state / tool history (in-memory only; LRU eviction loses state — known limitation)
- Concurrent same-conv_id request safety (read-modify-write race exists; same-conversation concurrent requests are rare and counter drift is non-critical in v1)
- Encryption of tool call history (consistent with unencrypted ConversationStore messages)
- UI changes to legion-interlink for displaying tool history
