# Design: Sticky Runner Tool Injection + Tool Call History

**Date**: 2026-04-15
**Repo**: legion-llm + LegionIO (cross-gem)
**Status**: Approved for implementation — post adversarial review rounds 1 + 2

---

## Problem

When the LLM calls a tool (e.g. `list_issues`), the runner that provided it (`github_issues`) only stays injected for that one turn. On the next turn, trigger matching starts fresh — if the user's follow-up message doesn't contain the right keyword, the runner isn't re-injected and the LLM can't call `create_issue` or `update_issue`. It falls back to `legion_do` or hallucinates.

Additionally, the LLM has no memory of what tools did in prior turns of the same conversation. It can't reference "the issue I created 2 turns ago was #142" without that context being explicitly provided.

---

## Solution Overview

Two coupled features stored in a dedicated per-conversation state slot in `ConversationStore` and surfaced on every subsequent pipeline turn:

1. **Sticky runner injection** — runners stay in the injected toolset for N message turns (trigger tier) or N deferred tool executions (execution tier) after activity. Window resets on re-trigger or re-execution; never shortens.

2. **Tool call history** — every tool call (name, sanitized args, summarized result, message turn) is appended to a per-conversation list. Injected into the system prompt as a structured enrichment block on subsequent turns so the LLM can reference prior results.

---

## Storage Model

Not stored via `store_metadata` / `read_metadata` (append-only with read-latest semantics — wrong for frequently-mutated structured state). Instead, a dedicated `sticky_state` slot on the conversation hash:

```ruby
conversations[conv_id][:sticky_state] = {
  sticky_runners: { ... },
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

# Writes state. Calls ensure_conversation (real write, side effect is acceptable).
def write_sticky_state(conversation_id, state)
  ensure_conversation(conversation_id)
  conversations[conversation_id][:sticky_state] = state
  touch(conversation_id)
end
```

`read_sticky_state` returns the live hash (not a dup). Callers MUST treat it as read-only and call `write_sticky_state` with a modified copy to persist changes. This mirrors how callers interact with the rest of `ConversationStore`.

**LRU eviction**: When `evict_if_needed` evicts a conversation that has a non-empty `sticky_state`, a warning is logged. Sticky state is in-memory only — no DB persistence in this iteration. This is a known limitation: if a conversation is evicted (MAX_CONVERSATIONS=256 is reached) and then resumed, sticky state is lost. See "Not Included".

**DB persistence**: In-memory only for now. `write_sticky_state` does not call `persist_message`. DB persistence follows the existing `persist_message` pattern and is deferred to a follow-up.

---

## Data Model

All keys are Ruby symbols throughout (consistent with `symbolize_names: true` used elsewhere in ConversationStore).

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

- **Key**: `"#{tool_class.extension}_#{tool_class.runner}"` — underscores throughout, matching exact output of `derive_extension_name` and `derive_runner_snake` in `Tools::Discovery`
- **`expires_after_deferred_call`**: execution-tier only — runner expires when `deferred_tool_calls >= this value`
- **`expires_at_turn`**: trigger-tier only — runner expires when message count `>= this value` (inclusive — runner is live through the turn where snapshot equals the expiry)
- **`deferred_tool_calls`**: counter of deferred tool executions only — always-loaded tools do NOT increment this counter. `Registry.deferred_tools` is the reference bucket. The clock represents "work done with specialized runners", not total tool activity
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

- `turn` — `ConversationStore.messages(conv_id).size` at call time — human-readable message-turn label. Separate from `deferred_tool_calls` clock.
- `result` — truncated to `max_result_length` chars
- `args` — sanitized before storage (see Arg Sanitization). Individual values truncated to `max_args_length`
- `error: true` when tool returned an error response

---

## Sticky Window Tiers

Two independent clocks — trigger stickiness counts message turns, execution stickiness counts deferred tool calls:

| Event | Clock | Window | Expiry stored as |
|-------|-------|--------|-----------------|
| Trigger word matched for runner | Message turns | `trigger_sticky_turns` (default: 2) | `expires_at_turn = snapshot + 2` |
| Deferred tool from runner executed | Deferred tool call count | `execution_sticky_tool_calls` (default: 5) | `expires_after_deferred_call = deferred_tool_calls + 5` |
| Re-trigger while triggered-sticky | Message turns | `max(current_expiry, snapshot + trigger_window)` | Never shortens |
| Re-execution while sticky (any tier) | Deferred call count | `max(current_expiry, deferred_tool_calls + execution_window)`, upgrade tier to `:executed` | Always upgrades |
| Trigger fires on currently execution-sticky runner | — | No-op — guard in persist: only apply trigger window if not already execution-sticky | Execution window preserved |
| Trigger fires on EXPIRED execution-sticky runner | Message turns | Fresh trigger — tier `:triggered`, `expires_at_turn = snapshot + trigger_window` | Re-activates under trigger tier |

Expiry comparison uses `>=` (inclusive): a runner is considered expired when `deferred_tool_calls >= expires_after_deferred_call` or `snapshot >= expires_at_turn`. This means the window is "live through N" not "live until N is reached."

**Why deferred-only counter?** Always-loaded tools (`legion_do`, `legion_status`) firing repeatedly should not drain the sticky window for specialized runners. The counter represents "work done with specific runners."

---

## Pipeline Changes

### Repos modified

- **legion-llm**: new step files, executor changes, conversation store methods, enrichment injector
- **LegionIO**: `Tools::Base` (sticky accessor), `Tools::Discovery` (set sticky on tool class, specify Registry bucket), `Extensions::Core` (sticky_tools? default)

**Release ordering**: LegionIO changes MUST be released before or simultaneously with legion-llm changes. `step_sticky_runners` guards all `tool_class.sticky` calls with `tool_class.respond_to?(:sticky)` to handle partial deployment safely.

### `@sticky_turn_snapshot` ivar

Initialized to `nil` in `Executor#initialize`. Set at the start of `step_sticky_runners` via `@sticky_turn_snapshot = ConversationStore.messages(conv_id).size`. Both the step and the persist step use this same snapshot — avoids one-off errors from message count changing mid-turn.

`step_sticky_runners_persist` checks `return unless @sticky_turn_snapshot` at its top — if the pre-provider step was skipped (profile skip), the persist step is a no-op.

### `@pending_tool_history` ivar

Initialized to `[]` in `Executor#initialize`. Populated exclusively by the `emit_tool_call_event` / `emit_tool_result_event` callbacks — which fire for BOTH streaming and non-streaming paths via `install_tool_loop_guard`. `step_tool_calls` does NOT append to `@pending_tool_history`.

**Why callbacks only?** `install_tool_loop_guard` installs `on_tool_call`/`on_tool_result` hooks on the RubyLLM session. These fire whenever `session.ask` dispatches tools, regardless of whether the outer call is streaming or not. `step_tool_calls` runs post-provider and dispatches via `ToolDispatcher` — a separate path that does NOT invoke the RubyLLM session callbacks. Using both paths would double-populate the accumulator.

**Arg/result pairing in callbacks**:

```ruby
def emit_tool_call_event(tool_call, round)
  tc_id   = tool_call_field(tool_call, :id)
  tc_name = tool_call_field(tool_call, :name)
  tc_args = tool_call_field(tool_call, :arguments) || {}

  # Push partial entry — result filled in by emit_tool_result_event
  @pending_tool_history << {
    tool_call_id: tc_id,
    tool_name:    tc_name,
    args:         tc_args,
    result:       nil,
    error:        false
  }

  # ... existing Thread.current tracking for timing/event handler ...
end

def emit_tool_result_event(tool_result)
  tc_id  = tool_result.respond_to?(:tool_call_id) ? tool_result.tool_call_id : Thread.current[:legion_current_tool_call_id]
  raw    = tool_result.respond_to?(:result) ? tool_result.result : tool_result

  # Find matching partial entry and fill in result
  entry = @pending_tool_history.find { |e| e[:tool_call_id] == tc_id }
  if entry
    entry[:result] = raw.is_a?(String) ? raw : raw.to_s
    entry[:error]  = raw.is_a?(Hash) && (raw[:error] || raw['error']) ? true : false
  end

  # ... existing event emission ...
end
```

---

## Steps

### New steps and their positions

**PRE_PROVIDER_STEPS** (between `trigger_match` and `tool_discovery`):
- `step_sticky_runners`
- `step_tool_history_inject`

**POST_PROVIDER_STEPS** (exact updated array):
```ruby
POST_PROVIDER_STEPS = %i[
  response_normalization metering debate confidence_scoring
  tool_calls tool_history_persist sticky_runners_persist
  context_store post_response knowledge_capture response_return
].freeze
```

`tool_history_persist` and `sticky_runners_persist` are after `tool_calls` (so `@pending_tool_history` is fully populated by the time they run) and before `context_store`.

### Profile skip lists

Add to `GAIA_SKIP`, `SYSTEM_SKIP`, `QUICK_REPLY_SKIP`, `SERVICE_SKIP`:
```ruby
:sticky_runners, :tool_history_inject, :tool_history_persist, :sticky_runners_persist
```

`:human` and `:external` profiles do NOT skip these steps — sticky behavior is for interactive sessions. When the persist steps are skipped for non-human profiles, `@pending_tool_history` is discarded with the Executor instance (per-request lifecycle — no leak).

---

#### 1. New: `lib/legion/llm/pipeline/steps/sticky_runners.rb`

Module `Steps::StickyRunners` included in `Executor`. Three methods:

**`step_sticky_runners`** (pre-provider):
```
return unless sticky_enabled? && conv_id
@sticky_turn_snapshot = ConversationStore.messages(conv_id).size
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
  # dedup against @triggered_tools
  @triggered_tools << tool_class unless @triggered_tools.map(&:tool_name).include?(tool_class.tool_name)
end
record enrichment + timeline
```

**`step_sticky_runners_persist`** (post-provider, after `tool_calls`):
```
return unless @sticky_turn_snapshot  # skipped if pre-provider step was profile-skipped
return unless sticky_enabled? && conv_id

state = ConversationStore.read_sticky_state(conv_id).dup
runners = (state[:sticky_runners] || {}).dup
deferred_count = state[:deferred_tool_calls] || 0

# Determine which runners had deferred tools executed this turn
executed_runner_keys = @pending_tool_history.filter_map { |entry|
  tc = Registry.find(entry[:tool_name])  # look up by tool name
  next unless tc&.deferred?
  "#{tc.extension}_#{tc.runner}"
}.uniq

# Increment deferred counter
deferred_count += executed_runner_keys.size
state[:deferred_tool_calls] = deferred_count

# Update execution-tier stickiness
executed_runner_keys.each do |key|
  existing = runners[key]
  new_expiry = deferred_count + execution_sticky_tool_calls
  if existing && existing[:tier] == :executed
    runners[key] = existing.merge(expires_after_deferred_call: [existing[:expires_after_deferred_call], new_expiry].max)
  else
    runners[key] = { tier: :executed, expires_after_deferred_call: new_expiry }
  end
end

# Update trigger-tier stickiness (only if not already execution-sticky)
(@triggered_tools.map { |t| "#{t.extension}_#{t.runner}" }.uniq - executed_runner_keys).each do |key|
  next if runners[key]&.dig(:tier) == :executed
  existing_expiry = runners.dig(key, :expires_at_turn) || 0
  new_expiry = @sticky_turn_snapshot + trigger_sticky_turns
  runners[key] = { tier: :triggered, expires_at_turn: [existing_expiry, new_expiry].max }
end

# Expired execution-sticky runners that were re-triggered (above) are now tier :triggered — correct

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
@enrichments['tool:call_history'] = format_history(history)
```

Format (pre-formatted string):
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
turn = @sticky_turn_snapshot || ConversationStore.messages(conv_id).size

@pending_tool_history.each do |entry|
  next unless entry[:result]  # skip incomplete entries (tool_call without result)
  history << {
    tool:   entry[:tool_name],
    runner: begin; tc = Registry.find(entry[:tool_name]); "#{tc&.extension}_#{tc&.runner}"; rescue; "unknown"; end,
    turn:   turn,
    args:   sanitize_args(truncate_args(entry[:args])),
    result: (entry[:result] || "").to_s[0, max_result_length],
    error:  entry[:error] || false
  }
end

# Trim to max_history_entries (keep most recent)
history = history.last(max_history_entries)

state[:tool_call_history] = history
ConversationStore.write_sticky_state(conv_id, state)
```

---

#### 3. `lib/legion/llm/pipeline/executor.rb`

- Include `Steps::StickyRunners` and `Steps::ToolHistory`
- Initialize in `initialize`: `@sticky_turn_snapshot = nil` and `@pending_tool_history = []`
- Update `STEPS`, `PRE_PROVIDER_STEPS`, `POST_PROVIDER_STEPS` as shown above
- Update `emit_tool_call_event` and `emit_tool_result_event` to maintain `@pending_tool_history` (see callback specification above)

---

#### 4. `lib/legion/llm/pipeline/enrichment_injector.rb`

Add `tool:call_history` AFTER skill injection (not before):

```ruby
# After skill:active block, before appending caller system prompt:
if (history = enrichments['tool:call_history'])
  parts << history
end
```

Order: baseline → GAIA system prompt → RAG context → skill → **tool history** → caller system prompt

Rationale: tool history is the most recent system-level context before the user's instructions. Placing it after skill injection ensures the skill's behavioral framing is set first, then the history provides grounding facts.

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

Default: `true` when never set. `false` only when explicitly set to `false` via `sticky(false)`.

#### `lib/legion/tools/discovery.rb`

In `tool_attributes`, add (boolean-coerced to prevent nil promotion):

```ruby
sticky: !!(ext.respond_to?(:sticky_tools?) ? ext.sticky_tools? : true)
```

`nil` from `sticky_tools?` becomes `false` via `!!nil`. This is conservative — if an extension returns nil from `sticky_tools?` that is treated as opt-out, not opt-in.

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

Instance method accessible on extension modules via `extend` (same mechanism as `mcp_tools?`, `remote_invocable?` etc. — see `extension.extend Legion::Extensions::Core` in extensions.rb). Extensions that opt out define `def self.sticky_tools? false end` which overrides the extended method.

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
    h[k] = v.to_s.length > max_args_length ? v.to_s[0, max_args_length] + '…' : v
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
- `spec/legion/llm/pipeline/steps/sticky_runners_spec.rb` — step injection, window tiers, >= expiry comparison, max rule, expired execution re-trigger, deferred-only counter, nil snapshot guard, profile skip behavior
- `spec/legion/llm/pipeline/steps/tool_history_spec.rb` — append, truncation, arg sanitization, result summarization, enrichment format, max_history_entries trim, incomplete entry skip
- `spec/legion/llm/pipeline/enrichment_injector_spec.rb` — history block injection after skill
- `spec/legion/llm/conversation_store_spec.rb` — `read_sticky_state` returns {} for unknown conv, `write_sticky_state` creates conv, eviction warning log
- `spec/legion/llm/pipeline/executor_spec.rb` — `@pending_tool_history` callback population, double-population prevention, nil conv_id guards, profile skip for all 4 new steps

**LegionIO**:
- `spec/legion/tools/base_spec.rb` — `sticky` accessor: default true, false when set, nil coercion
- `spec/legion/tools/discovery_spec.rb` — boolean coercion of sticky_tools? return, false for nil, Registry.deferred_tools used for lookup
- `spec/legion/extensions/core_spec.rb` — `sticky_tools?` default true

---

## Not Included

- Runner-level sticky opt-out (lex-level only)
- Compounding sticky windows (max rule only)
- DB-backed sticky state / tool history (in-memory only; LRU eviction loses state — known limitation)
- Concurrent same-conv_id request safety (read-modify-write race exists; same-conversation concurrent requests are rare and counter drift is non-critical in v1)
- Encryption of tool call history (consistent with unencrypted ConversationStore messages)
- UI changes to legion-interlink for displaying tool history
