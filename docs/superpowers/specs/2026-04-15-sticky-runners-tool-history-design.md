# Design: Sticky Runner Tool Injection + Tool Call History

**Date**: 2026-04-15
**Repo**: legion-llm
**Status**: Approved for implementation

---

## Problem

When the LLM calls a tool (e.g. `list_issues`), the runner that provided it (`github-issues`) only stays injected for that one turn. On the next turn, trigger matching starts fresh — if the user's follow-up message doesn't contain the right keyword, the runner isn't re-injected and the LLM can't call `create_issue` or `update_issue`. It falls back to `legion_do` or hallucinates.

Additionally, the LLM has no memory of what tools did in prior turns of the same conversation. It can't reference "the issue I created 2 turns ago was #142" without that context being explicitly provided.

---

## Solution Overview

Two coupled features stored in `ConversationStore` metadata and surfaced on every subsequent pipeline turn:

1. **Sticky runner injection** — runners stay in the injected toolset for N turns after trigger match or tool execution, with two tiers of window length. Window resets (never shortens, always upgrades to max) on re-trigger or re-execution.

2. **Tool call history** — every tool call (name, args, result, turn) is appended to a per-conversation list stored in metadata. Injected into the system prompt as a structured enrichment block on subsequent turns so the LLM can reference prior results.

---

## Data Model

Stored in `ConversationStore` metadata via `store_metadata` / `read_metadata` under two new keys:

### `sticky_runners`
```json
{
  "sticky_runners": {
    "github-issues": { "expires_after_tool_call": 12, "expires_at_turn": 8, "tier": "executed" },
    "github-branches": { "expires_at_turn": 5, "tier": "triggered" }
  },
  "total_tool_calls": 7
}
```

- **Key**: `"#{extension}-#{runner}"` (e.g. `"github-issues"`, `"apollo-knowledge"`)
- **`expires_after_tool_call`**: present only for `tier: "executed"` — the runner expires when `total_tool_calls >= expires_after_tool_call`. Counts down in tool executions, not messages, so a long back-and-forth without tool calls doesn't burn the window
- **`expires_at_turn`**: present only for `tier: "triggered"` — the runner expires when message count exceeds this value. Trigger stickiness is about user intent in words, so message turns are the right clock
- **`total_tool_calls`**: top-level counter incremented by 1 each time any tool is executed in this conversation. Used as the clock for execution-tier expiry
- **`tier`**: `"triggered"` or `"executed"` — determines which clock and window to use on reset

### `tool_call_history`
```json
{
  "tool_call_history": [
    {
      "tool": "legion-github-issues-list_issues",
      "runner": "github-issues",
      "turn": 3,
      "args": { "owner": "LegionIO", "repo": "legion-mcp", "state": "open" },
      "result": "{\"result\":[{\"number\":42,\"title\":\"Fix pipeline bug\"},...]}",
      "error": false
    },
    {
      "tool": "legion-github-issues-create_issue",
      "runner": "github-issues",
      "turn": 4,
      "args": { "owner": "LegionIO", "repo": "legion-mcp", "title": "Add sticky tools" },
      "result": "{\"result\":{\"number\":43,\"html_url\":\"https://github.com/...\"}}",
      "error": false
    }
  ]
}
```

- `result` is stored as a truncated string (max `max_result_length` chars) to bound context window cost
- `error: true` when the tool returned an error response
- `turn` is the value of `total_tool_calls` after this call — uniquely identifies position in the tool call sequence regardless of message count

---

## Sticky Window Tiers

Two independent clocks — trigger stickiness counts message turns, execution stickiness counts tool calls:

| Event | Clock | Window | Expiry stored as |
|-------|-------|--------|-----------------|
| Trigger word matched for runner | Message turns | `trigger_sticky_turns` (default: 2) | `expires_at_turn = current_message_count + 2` |
| Tool from runner executed | Tool call count | `execution_sticky_turns` (default: 5) | `expires_after_tool_call = total_tool_calls + 5` |
| Re-trigger while triggered-sticky | Message turns | Reset to `max(current_expiry, current_message_count + trigger_window)` | Never shortens |
| Re-execution while sticky | Tool call count | Reset to `max(current_expiry, total_tool_calls + execution_window)`, upgrade tier to `executed` | Always upgrades |
| Trigger fires on execution-sticky runner | — | No-op — execution window is already longer | Execution window preserved |

**Why two clocks?** Trigger stickiness is about user intent in words — it should fade after a couple of exchanges if the user moves on. Execution stickiness is about work in progress — a long back-and-forth discussion shouldn't burn through the window if no other tools are being called. A conversation where the user deliberates over 10 messages before creating a second issue keeps the runner available the whole time.

---

## Pipeline Changes

### Files modified (all in `legion-llm`)

#### 1. New: `lib/legion/llm/pipeline/steps/sticky_runners.rb`

Module `Steps::StickyRunners` included in `Executor`. Two responsibilities:

**`step_sticky_runners`** (pre-provider, added to `STEPS` between `trigger_match` and `tool_discovery`):
- Load metadata from `ConversationStore.read_metadata(conv_id)` → `sticky_runners`, `total_tool_calls`
- Calculate `current_message_count = ConversationStore.messages(conv_id).size`
- Filter runners: keep where `tier == "triggered" && expires_at_turn > current_message_count` OR `tier == "executed" && expires_after_tool_call > total_tool_calls`
- For each live sticky runner key, find all deferred tools in `Registry` where `"#{tool_class.extension}-#{tool_class.runner}" == key` and `tool_class.sticky != false`
- Merge into `@triggered_tools` (deduplicating)
- Record in `@enrichments['tool:sticky_runners']` for timeline

**`persist_sticky_runners`** (called from `step_context_store` after tool calls are known):
- Read current metadata snapshot
- Increment `total_tool_calls` by number of tools executed this turn
- For each executed runner: set `expires_after_tool_call = total_tool_calls + execution_sticky_turns`, tier = `"executed"` — apply `max` rule
- For each trigger-matched runner (from `@triggered_tools` minus executed): set `expires_at_turn = current_message_count + trigger_sticky_turns`, tier = `"triggered"` — only if not already execution-sticky
- Write back via `ConversationStore.store_metadata`

#### 2. New: `lib/legion/llm/pipeline/steps/tool_history.rb`

Module `Steps::ToolHistory` included in `Executor`. Two responsibilities:

**`step_tool_history_inject`** (pre-provider, added to `STEPS` between `sticky_runners` and `tool_discovery`):
- Load `tool_call_history` from metadata
- If non-empty, build enrichment string and write to `@enrichments['tool:call_history']`
- `EnrichmentInjector` picks this up and injects it into the system prompt

**`persist_tool_call_history`** (called from `step_context_store`):
- Build records from `response_tool_calls` (already populated in `build_response`)
- Append to existing history (no replacement — history only grows)
- Truncate result strings to 2000 chars
- Write back via `ConversationStore.store_metadata`

#### 3. `lib/legion/llm/pipeline/executor.rb`

- Include `Steps::StickyRunners` and `Steps::ToolHistory`
- Add `step_sticky_runners` and `step_tool_history_inject` to `STEPS`, `PRE_PROVIDER_STEPS`
- Call `persist_sticky_runners` and `persist_tool_call_history` from `step_context_store`

#### 4. `lib/legion/llm/pipeline/enrichment_injector.rb`

Add handling for `'tool:call_history'` enrichment key:

```ruby
if (history = enrichments['tool:call_history'])
  parts << history
end
```

Format injected into system prompt:
```
Tools used in this conversation:
- Turn 3: list_issues(owner: LegionIO, repo: legion-mcp, state: open) → 5 open issues returned
- Turn 4: create_issue(owner: LegionIO, repo: legion-mcp, title: Add sticky tools) → issue #43 created at https://github.com/...
```

Result summaries are condensed: JSON results are summarized to key fields (issue number, URL, count) rather than dumped verbatim — keeps the system prompt tight.

---

## `store_metadata` Extension

`ConversationStore.store_metadata` currently only accepts `title:`, `tags:`, `model:`. It needs to accept arbitrary keyword args and merge them into the stored payload. The read side already parses the full JSON blob, so `read_metadata` needs no change.

```ruby
# before
def store_metadata(conversation_id, title: nil, tags: nil, model: nil)
  payload = { title: title, tags: tags, model: model }.compact

# after
def store_metadata(conversation_id, title: nil, tags: nil, model: nil, **extra)
  payload = { title: title, tags: tags, model: model }.merge(extra).compact
```

This is a minimal backwards-compatible change.

---

## Result Summarization

Full JSON results are too verbose for the system prompt. A lightweight summarizer in `Steps::ToolHistory` extracts the most useful fields:

- If result contains `"number"` and `"html_url"` → `"issue #N created at URL"`
- If result is an array → `"N items returned"`
- If result contains `"error"` → `"error: <message>"`
- Otherwise → first `max_result_length` chars of result string

This is intentionally simple — no LLM involvement, pure string heuristics.

---

## Settings

All numeric thresholds are configurable — no magic numbers in code. All settings are optional with the defaults shown.

```json
{
  "llm": {
    "tool_sticky": {
      "enabled": true,
      "trigger_turns": 2,
      "execution_tool_calls": 5,
      "max_history_entries": 50,
      "max_result_length": 2000
    }
  }
}
```

- `trigger_turns` — message turns before a trigger-matched runner expires
- `execution_tool_calls` — tool call executions before an execution-sticky runner expires (not message turns)

Settings path helpers (used throughout the two new step modules):

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
```

---

## Spec Coverage

- `spec/legion/llm/pipeline/steps/sticky_runners_spec.rb` — step injection, window tiers, max rule, expiry filtering, persist logic
- `spec/legion/llm/pipeline/steps/tool_history_spec.rb` — append, truncation, summarization, enrichment format
- `spec/legion/llm/pipeline/enrichment_injector_spec.rb` — history block injection
- `spec/legion/llm/conversation_store_spec.rb` — `store_metadata` with extra kwargs

---

## Lex-Level Opt-Out

`Legion::Extensions::Core` gets a new `sticky_tools?` method defaulting to `true`. Extensions that should never be sticky (e.g. sensitive operation runners where every call requires fresh explicit intent) can override it:

```ruby
# in Core
def sticky_tools?
  true
end

# in an extension that opts out
def self.sticky_tools?
  false
end
```

During `Tools::Discovery#create_tool_class`, a `sticky` attribute is set on the tool class from `ext.respond_to?(:sticky_tools?) ? ext.sticky_tools? : true`. `Tools::Base` gets a `sticky(val = nil)` accessor alongside the existing `deferred`, `extension`, `runner` attributes.

`step_sticky_runners` skips any runner where its tools have `sticky: false`.

Runner-level opt-out is **not included** — lex-level covers all realistic cases.

---

## Not Included

- Per-tool stickiness (runner-level only)
- Compounding sticky windows (max rule only)
- DB-backed tool history (in-memory ConversationStore only for now — DB persistence follows the existing ConversationStore DB pattern and can be added later)
- UI changes to legion-interlink for displaying tool history
