# Design: Sticky Runner Tool Injection + Tool Call History

**Date**: 2026-04-15
**Repo**: legion-llm + LegionIO (cross-gem)
**Status**: Approved for implementation — post adversarial review rounds 1–5

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
# Does NOT call ensure_conversation — avoids resurrecting an evicted conversation
# as an empty shell that would clobber DB-loaded message history on the next
# step_context_load call.
def write_sticky_state(conversation_id, state)
  return unless in_memory?(conversation_id)
  conversations[conversation_id][:sticky_state] = state
  touch(conversation_id)
end
```

`read_sticky_state` returns the live hash (not a dup). Callers MUST treat it as read-only and build a modified copy before calling `write_sticky_state`. The single `step_sticky_persist` step (see Pipeline Changes) reads once, mutates a copy, writes once — eliminates any cross-step clobber risk.

**LRU eviction**: When `evict_if_needed` evicts a conversation that has a non-empty `sticky_state`, a warning is logged. Sticky state is in-memory only — no DB persistence in this iteration. Known limitation: if a conversation is evicted (MAX_CONVERSATIONS=256 reached) and then resumed, sticky state is silently lost.

---

## Data Model

All keys are Ruby symbols throughout.

### `sticky_runners`

```ruby
{
  sticky_runners: {
    "github_issues"   => { expires_after_deferred_call: 12, tier: :executed },
    "github_branches" => { expires_at_turn: 5, tier: :triggered }
  },
  deferred_tool_calls: 7
}
```

- **Key**: `"#{tool_class.extension}_#{tool_class.runner}"` — underscores, matching `derive_extension_name` + `derive_runner_snake`
- **`expires_after_deferred_call`**: execution-tier — runner expires when `deferred_tool_calls >= this value`
- **`expires_at_turn`**: trigger-tier — runner expires when human turn count `>= this value`
- **`deferred_tool_calls`**: count of individual deferred tool executions that completed successfully. Always-loaded tools do NOT increment this counter.
- **`tier`**: `:triggered` or `:executed`

### `tool_call_history`

```ruby
{
  tool_call_history: [
    {
      tool:       "legion-github-issues-list_issues",
      runner:     "github_issues",
      turn:       3,
      args:       { owner: "LegionIO", repo: "legion-mcp", state: "open" },
      result:     '{"result":[{"number":42,"title":"Fix pipeline bug"},...]}',
      error:      false
    }
  ]
}
```

- `turn` — human turn count (`@sticky_turn_snapshot`) at call time
- `result` — truncated to `max_result_length` chars
- `args` — sanitized and truncated (see Arg Sanitization)
- `error: true` when tool returned an error response

---

## Sticky Window Tiers

Two independent clocks — trigger stickiness counts human turns (user messages only), execution stickiness counts individual successful deferred tool executions:

| Event | Clock | Window | Expiry stored as |
|-------|-------|--------|-----------------|
| Trigger word matched for runner | Human turns | `trigger_sticky_turns` (default: 2) | `expires_at_turn = snapshot + trigger_sticky_turns + 1` (the +1 accounts for the current user message not yet stored at snapshot time) |
| Deferred tool from runner executed successfully | Deferred tool call count | `execution_sticky_tool_calls` (default: 5) | `expires_after_deferred_call = deferred_tool_calls + 5` |
| Re-trigger while triggered-sticky | Human turns | `max(current_expiry, snapshot + trigger_window)` | Never shortens |
| Re-execution while sticky (any tier) | Deferred call count | `max(current_expiry, deferred_tool_calls + execution_window)`, upgrade tier to `:executed` | Always upgrades |
| Trigger fires on currently execution-sticky runner | — | No-op — guard in persist: skip if already execution-sticky | Execution window preserved |
| Trigger fires on EXPIRED execution-sticky runner | Human turns | Fresh trigger — tier `:triggered`, `expires_at_turn = snapshot + trigger_window` | Re-activates under trigger tier |

Live check uses strict `<`: a runner is live while `snapshot < expires_at_turn` or `deferred_tool_calls < expires_after_deferred_call`.

**Why human turn count?** Each human turn adds at least 2 raw messages (user + assistant). Using raw `ConversationStore.messages.size` would make `trigger_sticky_turns=2` expire after ~1 human interaction. The snapshot counts only user-role messages: `messages.count { |m| (m[:role] || m['role']).to_s == 'user' }`.

**Why deferred-only counter?** Always-loaded tools shouldn't drain the window for specialized runners.

---

## Pipeline Changes

### Repos modified

- **legion-llm**: new step files, executor changes, conversation store methods, enrichment injector, profile skip lists
- **LegionIO**: `Tools::Base` (sticky accessor), `Tools::Discovery` (set sticky, Registry bucket), `Extensions::Core` (sticky_tools? default)

**Release ordering**: LegionIO MUST be released before or simultaneously with legion-llm. `step_sticky_runners` guards `tool_class.sticky` with `tool_class.respond_to?(:sticky)` for partial deployment safety.

### Key ivars (all initialized in `Executor#initialize`)

| Ivar | Init | Purpose |
|------|------|---------|
| `@sticky_turn_snapshot` | `nil` | Human turn count at pre-provider time; nil signals profile-skipped |
| `@pending_tool_history` | `[]` | Accumulates tool call records from callbacks + step_tool_calls |
| `@injected_tool_map` | `{}` | Sanitized tool name → tool class; built during inject_registry_tools |
| `@freshly_triggered_keys` | `[]` | Runner keys from trigger_match only (not sticky re-injections) |

### `@sticky_turn_snapshot`

Set as the **first statement** in `step_sticky_runners`, before any modification to `@triggered_tools`:

```ruby
@sticky_turn_snapshot = ConversationStore.messages(conv_id)
                          .count { |m| (m[:role] || m['role']).to_s == 'user' }
```

### `@freshly_triggered_keys`

Set as the **second statement** in `step_sticky_runners`, immediately after the snapshot — before the sticky re-injection loop:

```ruby
@freshly_triggered_keys = @triggered_tools.map { |t| "#{t.extension}_#{t.runner}" }.uniq
```

**Critical ordering**: this MUST be captured before the re-injection loop appends tools to `@triggered_tools`. If captured after, sticky re-injected runners would be included and their trigger windows would refresh every turn, making trigger stickiness self-perpetuating.

### `@injected_tool_map`

Built during `inject_registry_tools` — **in ALL THREE injection loops** (always-loaded, trigger-matched, requested-deferred):

```ruby
adapter = ToolAdapter.new(tool_class)
@injected_tool_map[adapter.name] = tool_class  # add to ALL three loops
session.with_tool(adapter)
```

In `step_sticky_persist`, rather than calling `Registry.find` N times in a loop (mutex contention), take a single snapshot at the start of the step:

```ruby
tool_snapshot = defined?(::Legion::Tools::Registry) ?
  ::Legion::Tools::Registry.all_tools.each_with_object({}) { |t, h| h[t.tool_name] = t } :
  {}
```

Then resolve tool class via:
```ruby
tc = @injected_tool_map[entry[:tool_name]] || tool_snapshot[entry[:tool_name]]
```

Handles native dispatch (map empty), tools-opt-out (`tools: []`), and all Registry tools with a single mutex acquisition.

For `step_tool_calls` tools (MCP/ToolDispatcher path), the `runner_key` is derived directly at append time from the `source` hash. **Normalize `source[:lex]` to match `derive_extension_name` format** (strip `lex-` prefix, replace hyphens with underscores):

```ruby
lex_normalized = (source[:lex] || '').delete_prefix('lex-').tr('-', '_')
runner_key = source[:type] == :extension ? "#{lex_normalized}_#{source[:runner]}" : nil
@pending_tool_history << { ..., runner_key: runner_key }
```

Persist steps check `entry[:runner_key]` first, then fall back to map + snapshot.

### `@pending_tool_history` and `@pending_tool_history_mutex`

Both initialized in `Executor#initialize`:
- `@pending_tool_history = []`
- `@pending_tool_history_mutex = Mutex.new`

The mutex is required because `ruby_llm_parallel_tools.rb` spawns a thread per tool call in a batch. `emit_tool_call_event` and `emit_tool_result_event` both access `@pending_tool_history` concurrently. All reads and writes must be wrapped in `@pending_tool_history_mutex.synchronize`.

Two population sources (mutually exclusive paths — no double-population):

1. **RubyLLM callbacks** (`emit_tool_call_event` / `emit_tool_result_event`) — for tools dispatched natively via `session.ask`. Callbacks fire for both streaming and non-streaming RubyLLM paths, including parallel tool batches.
2. **`step_tool_calls`** — for MCP and ToolDispatcher tools. Sets both args and result in one shot. Includes `runner_key` pre-computed from source. Runs post-provider (single thread), no mutex needed for this path.

### Single persist step

Both sticky runner state and tool history are mutated in a single `step_sticky_persist` step that reads state once, applies both mutations, writes once. This eliminates the read-modify-write clobber that would occur if two independent persist steps each wrote to the same `sticky_state` slot.

---

### Updated step arrays

```ruby
PRE_PROVIDER_STEPS = %i[
  tracing_init idempotency conversation_uuid context_load
  rbac classification billing gaia_advisory tier_assignment rag_context
  trigger_match sticky_runners skill_injector tool_history_inject tool_discovery
  routing request_normalization token_budget
].freeze

POST_PROVIDER_STEPS = %i[
  response_normalization metering debate confidence_scoring
  tool_calls sticky_persist
  context_store post_response knowledge_capture response_return
].freeze

# STEPS must be kept in sync — used by the synchronous Executor#call path
STEPS = (PRE_PROVIDER_STEPS + %i[provider_call] + POST_PROVIDER_STEPS).freeze
```

`sticky_runners` goes after `trigger_match` (so `@triggered_tools` from trigger_match is captured in `@freshly_triggered_keys`) and before `skill_injector` (so skills see the full re-injected toolset). `tool_history_inject` goes after `skill_injector` and before `tool_discovery` (history is enrichment context, not tool discovery). `sticky_persist` goes after `tool_calls` (so `@pending_tool_history` is fully populated) and before `context_store`.

**Important**: `STEPS` must also be updated — it is used by the synchronous `Executor#call` path (`execute_steps`). Without updating `STEPS`, all sticky behavior silently skips for non-streaming callers.

### Profile skip lists

Add to `GAIA_SKIP`, `SYSTEM_SKIP`, `SERVICE_SKIP`, `QUICK_REPLY_SKIP`:
```ruby
:sticky_runners, :tool_history_inject, :sticky_persist
```

`:human` and `:external` profiles do NOT skip — sticky behavior is for interactive sessions. When persist is skipped for non-human profiles, `@pending_tool_history` is discarded with the Executor instance (per-request lifecycle).

---

#### 1. New: `lib/legion/llm/pipeline/steps/sticky_runners.rb`

Module `Steps::StickyRunners` included in `Executor`.

**`step_sticky_runners`** (pre-provider, after `trigger_match`):

```ruby
def step_sticky_runners
  return unless sticky_enabled? && @request.conversation_id
  conv_id = @request.conversation_id

  # MUST be first — before any modification to @triggered_tools
  @sticky_turn_snapshot = ConversationStore.messages(conv_id)
                            .count { |m| (m[:role] || m['role']).to_s == 'user' }

  # MUST be second — captures trigger_match results before sticky re-injection
  @freshly_triggered_keys = @triggered_tools.map { |t| "#{t.extension}_#{t.runner}" }.uniq

  state = ConversationStore.read_sticky_state(conv_id)
  runners = state[:sticky_runners] || {}
  deferred_count = state[:deferred_tool_calls] || 0

  live_keys = runners.select do |_k, v|
    (v[:tier] == :triggered && @sticky_turn_snapshot < v[:expires_at_turn]) ||
    (v[:tier] == :executed  && deferred_count < v[:expires_after_deferred_call])
  end.keys

  Registry.deferred_tools.each do |tool_class|
    key = "#{tool_class.extension}_#{tool_class.runner}"
    next unless live_keys.include?(key)
    next if tool_class.respond_to?(:sticky) && tool_class.sticky == false
    next if @triggered_tools.any? { |t| t.tool_name == tool_class.tool_name }
    @triggered_tools << tool_class
  end

  @enrichments['tool:sticky_runners'] = {
    content:   "#{live_keys.size} runners re-injected via stickiness",
    data:      { runner_keys: live_keys },
    timestamp: Time.now
  }
  @timeline.record(category: :enrichment, key: 'tool:sticky_runners',
                   direction: :inbound, detail: "#{live_keys.size} sticky runners",
                   from: 'sticky_state', to: 'pipeline')
rescue StandardError => e
  @warnings << "sticky_runners error: #{e.message}"
  handle_exception(e, level: :warn, operation: 'llm.pipeline.step_sticky_runners')
end
```

---

#### 2. New: `lib/legion/llm/pipeline/steps/tool_history.rb`

Module `Steps::ToolHistory` included in `Executor`.

**`step_tool_history_inject`** (pre-provider, after `skill_injector`):

```ruby
def step_tool_history_inject
  return unless sticky_enabled? && @request.conversation_id
  state = ConversationStore.read_sticky_state(@request.conversation_id)
  history = state[:tool_call_history] || []
  return if history.empty?

  @enrichments['tool:call_history'] = {
    content:   format_history(history),
    data:      { entry_count: history.size },
    timestamp: Time.now
  }
rescue StandardError => e
  @warnings << "tool_history_inject error: #{e.message}"
  handle_exception(e, level: :warn, operation: 'llm.pipeline.step_tool_history_inject')
end
```

**`format_history`** (private method in `Steps::ToolHistory`):

```ruby
def format_history(history)
  lines = history.map { |entry| format_history_entry(entry) }
  "Tools used in this conversation:\n#{lines.join("\n")}"
end

def format_history_entry(entry)
  # Serialize non-string values to JSON to avoid Ruby inspect output in LLM context
  args_str = (entry[:args] || {}).map do |k, v|
    val = v.is_a?(String) ? v : Legion::JSON.dump(v)
    "#{k}: #{val}"
  end.join(', ')
  summary = summarize_result(entry[:result], entry[:error])
  "- Turn #{entry[:turn]}: #{entry[:tool]}(#{args_str}) → #{summary}"
end

def summarize_result(result_str, error)
  return "error: #{result_str.to_s[0, 100]}" if error

  begin
    parsed = Legion::JSON.load(result_str.to_s)
  rescue StandardError
    return result_str.to_s[0, 200]
  end

  if parsed.is_a?(Array)
    "#{parsed.size} items returned"
  elsif parsed.is_a?(Hash)
    if parsed[:number] && parsed[:html_url]
      "##{parsed[:number]} at #{parsed[:html_url]}"
    elsif parsed[:result].is_a?(Array)
      "#{parsed[:result].size} items returned"
    elsif parsed[:result].is_a?(Hash) && parsed[:result][:number]
      "##{parsed[:result][:number]} at #{parsed[:result][:html_url]}"
    else
      result_str.to_s[0, 200]
    end
  else
    result_str.to_s[0, 200]
  end
end
```

---

#### 3. New: `lib/legion/llm/pipeline/steps/sticky_persist.rb`

Module `Steps::StickyPersist` included in `Executor`. Single step that handles both sticky runner and tool history persistence in one read-modify-write cycle.

**`step_sticky_persist`** (post-provider, after `tool_calls`):

```ruby
def step_sticky_persist
  return unless @sticky_turn_snapshot  # skipped if pre-provider was profile-skipped
  return unless sticky_enabled? && @request.conversation_id
  conv_id = @request.conversation_id

  state        = ConversationStore.read_sticky_state(conv_id).dup
  runners      = (state[:sticky_runners] || {}).dup
  deferred_count = state[:deferred_tool_calls] || 0

  # ── Sticky runners persist ─────────────────────────────────────────────
  # Snapshot Registry once (single mutex acquisition) rather than calling
  # Registry.find N times in the loop
  tool_snapshot = defined?(::Legion::Tools::Registry) ?
    ::Legion::Tools::Registry.all_tools.each_with_object({}) { |t, h| h[t.tool_name] = t } :
    {}

  pending_snapshot = @pending_tool_history_mutex.synchronize { @pending_tool_history.dup }
  completed = pending_snapshot.select { |e| e[:result] && !e[:error] }

  executed_runner_keys = []
  deferred_call_count  = 0

  completed.each do |entry|
    tc = @injected_tool_map[entry[:tool_name]] || tool_snapshot[entry[:tool_name]]
    next unless tc&.deferred?
    key = entry[:runner_key] || "#{tc.extension}_#{tc.runner}"
    executed_runner_keys << key
    deferred_call_count  += 1
  end

  executed_runner_keys.uniq!
  deferred_count += deferred_call_count
  state[:deferred_tool_calls] = deferred_count

  executed_runner_keys.each do |key|
    existing   = runners[key]
    new_expiry = deferred_count + execution_sticky_tool_calls
    runners[key] = {
      tier: :executed,
      expires_after_deferred_call: [existing&.dig(:expires_after_deferred_call) || 0, new_expiry].max
    }
  end

  (@freshly_triggered_keys - executed_runner_keys).each do |key|
    next if runners[key]&.dig(:tier) == :executed
    existing_expiry = runners.dig(key, :expires_at_turn) || 0
    # +1 accounts for the current user message not yet stored at snapshot time.
    # Without it, first-turn triggers would expire one turn early.
    new_expiry      = @sticky_turn_snapshot + trigger_sticky_turns + 1
    runners[key]    = { tier: :triggered, expires_at_turn: [existing_expiry, new_expiry].max }
  end

  state[:sticky_runners] = runners

  # ── Tool history persist ───────────────────────────────────────────────
  if @pending_tool_history.any?
    history = (state[:tool_call_history] || []).dup

    pending_snapshot.each do |entry|
      next unless entry[:result]
      tc = @injected_tool_map[entry[:tool_name]] || tool_snapshot[entry[:tool_name]]
      runner_key = entry[:runner_key] ||
                   (tc ? "#{tc.extension}_#{tc.runner}" : "unknown")
      history << {
        tool:   entry[:tool_name],
        runner: runner_key,
        turn:   @sticky_turn_snapshot,
        args:   sanitize_args(truncate_args(entry[:args] || {})),
        result: entry[:result].to_s[0, max_result_length],
        error:  entry[:error] || false
      }
    end

    state[:tool_call_history] = history.last(max_history_entries)
  end

  ConversationStore.write_sticky_state(conv_id, state)
rescue StandardError => e
  @warnings << "sticky_persist error: #{e.message}"
  handle_exception(e, level: :warn, operation: 'llm.pipeline.step_sticky_persist')
end
```

---

#### 4. `lib/legion/llm/pipeline/enrichment_injector.rb`

Add `tool:call_history` BEFORE the `return system if parts.empty?` guard and AFTER skill injection:

```ruby
parts << baseline if baseline
# GAIA system prompt
if (gaia = enrichments.dig('gaia:system_prompt', :content))
  parts << gaia
end
# RAG context
if (rag = enrichments.dig('rag:context_retrieval', :data, :entries))
  context_text = rag.map { |e| "[#{e[:content_type]}] #{e[:content]}" }.join("\n")
  parts << "Relevant context:\n#{context_text}" unless context_text.empty?
end
# Skill injection
parts << enrichments['skill:active'] if enrichments['skill:active']
# Tool call history — BEFORE the empty-parts guard so it reaches the LLM
# even when no other enrichments are present
if (history_block = enrichments.dig('tool:call_history', :content))
  parts << history_block
end

return system if parts.empty?

parts << system if system
parts.join("\n\n")
```

Order: baseline → GAIA → RAG → skill → **tool history** → (empty guard) → caller system prompt.

---

#### 5. `lib/legion/llm/pipeline/executor.rb`

- Include `Steps::StickyRunners`, `Steps::ToolHistory`, `Steps::StickyPersist`
- Initialize: `@sticky_turn_snapshot = nil`, `@pending_tool_history = []`, `@pending_tool_history_mutex = Mutex.new`, `@injected_tool_map = {}`, `@freshly_triggered_keys = []`
- Update `STEPS`, `PRE_PROVIDER_STEPS`, `POST_PROVIDER_STEPS` as shown in Updated step arrays
- Update `inject_registry_tools` — add `@injected_tool_map[adapter.name] = tool_class` in ALL THREE loops
- Update `emit_tool_call_event` — push partial entry with `pending_index`
- Update `emit_tool_result_event` — find by `tool_call_id`, fallback to `pending_index`, guard `entry[:result].nil?`
- Update `step_tool_calls` — append completed entries to `@pending_tool_history` with pre-computed `runner_key`

**`emit_tool_call_event` additions** (all access to `@pending_tool_history` must be synchronized):
```ruby
@pending_tool_history_mutex.synchronize do
  pending_index = @pending_tool_history.size
  @pending_tool_history << {
    tool_call_id:  tc_id,
    pending_index: pending_index,
    tool_name:     tc_name,
    args:          tc_args,
    result:        nil,
    error:         false,
    runner_key:    nil
  }
  Thread.current[:legion_current_tool_history_index] = pending_index
end
```

**`emit_tool_result_event` additions** (synchronized; rely on `tool_call_id` under parallel execution — Thread.current index unreliable across threads):
```ruby
@pending_tool_history_mutex.synchronize do
  # guard result.nil? to avoid re-matching on nil-id providers with multiple calls
  entry = @pending_tool_history.find { |e| e[:tool_call_id] == tc_id && e[:result].nil? }
  entry ||= @pending_tool_history[Thread.current[:legion_current_tool_history_index]]
  if entry
    entry[:result] = raw.is_a?(String) ? raw : raw.to_s
    entry[:error]  = raw.is_a?(Hash) && (raw[:error] || raw['error']) ? true : false
  end
end
```

**`step_tool_calls` addition** (after each tool dispatch — runs post-provider in single thread, no mutex needed):
```ruby
# Normalize source[:lex] to match derive_extension_name format
lex_normalized = (source[:lex] || '').delete_prefix('lex-').tr('-', '_')
runner_key     = source[:type] == :extension ? "#{lex_normalized}_#{source[:runner]}" : nil
# Coerce result to string — result[:result] can be any Ruby object from runner
result_string  = result[:result].is_a?(String) ? result[:result] : Legion::JSON.dump(result[:result] || {})
@pending_tool_history << {
  tool_call_id:  tool_call_id,
  pending_index: @pending_tool_history.size,
  tool_name:     tool_name,
  args:          tc[:arguments] || tc['arguments'] || {},
  result:        result_string,
  error:         result[:status] == :error,
  runner_key:    runner_key
}
```

---

#### 6. `lib/legion/llm/conversation_store.rb`

Add `read_sticky_state` and `write_sticky_state` as shown in Storage Model.

Update `evict_if_needed`:
```ruby
if conversations[oldest_id]&.dig(:sticky_state)&.any?
  log&.warn("[ConversationStore] evicting #{oldest_id} with non-empty sticky_state — sticky state lost")
end
conversations.delete(oldest_id)
```

---

### LegionIO changes

#### `lib/legion/tools/base.rb`

```ruby
def sticky(val = nil)
  return @sticky.nil? ? true : @sticky if val.nil?
  @sticky = val
end
```

#### `lib/legion/tools/discovery.rb`

In `tool_attributes`:
```ruby
sticky: !!(ext.respond_to?(:sticky_tools?) ? ext.sticky_tools? : true)
```
`nil` from `sticky_tools?` → `false` (conservative opt-out via `!!nil`).

In `create_tool_class`:
```ruby
sticky(attrs[:sticky])
```

Use `Registry.deferred_tools` when searching for sticky tools to re-inject.

#### `lib/legion/extensions/core.rb`

```ruby
def sticky_tools?
  true
end
```

Instance method accessible via `extend` (same mechanism as `mcp_tools?`). Opt-out: `def self.sticky_tools? false end`.

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

```ruby
def sticky_enabled?           = Legion::Settings.dig(:llm, :tool_sticky, :enabled) != false
def trigger_sticky_turns      = Legion::Settings.dig(:llm, :tool_sticky, :trigger_turns) || 2
def execution_sticky_tool_calls = Legion::Settings.dig(:llm, :tool_sticky, :execution_tool_calls) || 5
def max_history_entries       = Legion::Settings.dig(:llm, :tool_sticky, :max_history_entries) || 50
def max_result_length         = Legion::Settings.dig(:llm, :tool_sticky, :max_result_length) || 2000
def max_args_length           = Legion::Settings.dig(:llm, :tool_sticky, :max_args_length) || 500
```

---

## Lex-Level Opt-Out

```ruby
# Core default (instance method, accessible via extend)
def sticky_tools?
  true
end

# Extension opt-out
def self.sticky_tools?
  false
end
```

`tool_attributes` boolean-coerces: `nil` from `sticky_tools?` → `false`.

---

## Spec Coverage

**legion-llm**:
- `spec/legion/llm/pipeline/steps/sticky_runners_spec.rb` — snapshot counting user-role only, `@freshly_triggered_keys` captured before re-injection, live check strict `<`, profile skip nil-snapshot guard, re-injection dedup, Registry.deferred_tools lookup
- `spec/legion/llm/pipeline/steps/tool_history_spec.rb` — format_history output, summarize_result heuristics (array/object/error/plain), enrichment structure `{content:,data:,timestamp:}`
- `spec/legion/llm/pipeline/steps/sticky_persist_spec.rb` — single read-modify-write, deferred counter increments by call count, runner key from runner_key field vs map vs Registry, execution-tier advance, trigger-tier advance (freshly_triggered_keys only), error entries excluded from counter, max_history_entries trim, profile skip guard
- `spec/legion/llm/pipeline/enrichment_injector_spec.rb` — tool history injected BEFORE empty-parts guard (history present, no other enrichments → history reaches LLM), order after skill
- `spec/legion/llm/conversation_store_spec.rb` — `read_sticky_state` returns frozen {} for unknown conv, `write_sticky_state` no-ops for unknown conv, `write_sticky_state` persists to in-memory conv, `write_sticky_state` calls touch, `read_sticky_state`→`write_sticky_state` round-trip, eviction warning log
- `spec/legion/llm/pipeline/executor_spec.rb` — `@injected_tool_map` populated in all three inject loops, `emit_tool_result_event` nil-id result.nil? guard, `step_tool_calls` appends with runner_key, profile skip for all three new steps

**LegionIO**:
- `spec/legion/tools/base_spec.rb` — sticky default true, false when set, nil call is read-only
- `spec/legion/tools/discovery_spec.rb` — boolean coerce nil→false, true→true, false→false; deferred_tools for sticky lookup
- `spec/legion/extensions/core_spec.rb` — sticky_tools? default true

---

## Not Included

- Runner-level sticky opt-out (lex-level only)
- Compounding sticky windows (max rule only)
- DB-backed sticky state / tool history (in-memory only; LRU eviction loses state — known limitation)
- Concurrent same-conv_id request safety (read-modify-write race exists; non-critical in v1)
- Encryption of tool call history
- UI changes to legion-interlink
- External MCP tool executions (source type `:mcp`) do not advance sticky runner windows or increment the deferred tool call counter — no Registry entry exists to determine `runner_key` or `deferred?` status. They appear in tool history with `runner: "unknown"`.
- Caller-provided tools passed via `@request.tools` are not tracked in `@injected_tool_map` and will not advance sticky runner windows unless they are also registered in `Registry`.
