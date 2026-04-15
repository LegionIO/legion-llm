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
    "github-issues": { "expires_at_turn": 8, "tier": "executed" },
    "github-branches": { "expires_at_turn": 5, "tier": "triggered" }
  }
}
```

- **Key**: `"#{extension}-#{runner}"` (e.g. `"github-issues"`, `"apollo-knowledge"`)
- **`expires_at_turn`**: turn number after which this runner is no longer injected
- **`tier`**: `"triggered"` or `"executed"` — informational, used to determine which window to apply on reset

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

- `result` is stored as a truncated string (max 2000 chars) to bound context window cost
- `error: true` when the tool returned an error response
- `turn` is `ConversationStore.messages(conv_id).size` at time of call — a monotonically increasing proxy for turn number

---

## Sticky Window Tiers

| Event | Window | Example |
|-------|--------|---------|
| Trigger word matched for runner | `trigger_sticky_turns` (default: 2) | User asked "what issues exist?" |
| Tool from runner executed | `execution_sticky_turns` (default: 5) | LLM called `list_issues` |
| Re-trigger while sticky | Reset to `max(current_expiry, turn + trigger_window)` | Never shortens existing window |
| Re-execution while sticky | Reset to `max(current_expiry, turn + execution_window)` | Always upgrades to execution tier |

Settings path: `Legion::Settings.dig(:llm, :tool_sticky, :trigger_turns)` and `:execution_turns`.

---

## Pipeline Changes

### Files modified (all in `legion-llm`)

#### 1. New: `lib/legion/llm/pipeline/steps/sticky_runners.rb`

Module `Steps::StickyRunners` included in `Executor`. Two responsibilities:

**`step_sticky_runners`** (pre-provider, added to `STEPS` between `trigger_match` and `tool_discovery`):
- Load `sticky_runners` from `ConversationStore.read_metadata(conv_id)`
- Calculate `current_turn = ConversationStore.messages(conv_id).size`
- Filter to entries where `expires_at_turn > current_turn`
- For each live sticky runner key (`"github-issues"`), find all deferred tools in `Registry` where `tool_class.extension + "-" + tool_class.runner == key`
- Merge into `@triggered_tools` (deduplicating against already-triggered tools)
- Record in `@enrichments['tool:sticky_runners']` for timeline

**`persist_sticky_runners`** (called from `step_context_store` after tool calls are known):
- Extract runner keys from `@raw_response.tool_calls` via Registry lookup
- For each: set `expires_at_turn = current_turn + execution_sticky_turns`
- Merge with existing `sticky_runners` using `max` rule (never shorten)
- Also update trigger-tier runners from `@triggered_tools` using `trigger_sticky_turns`
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
- Otherwise → first 200 chars of result string

This is intentionally simple — no LLM involvement, pure string heuristics.

---

## Settings

```json
{
  "llm": {
    "tool_sticky": {
      "enabled": true,
      "trigger_turns": 2,
      "execution_turns": 5,
      "max_history_entries": 50
    }
  }
}
```

All settings are optional with the above defaults.

---

## Spec Coverage

- `spec/legion/llm/pipeline/steps/sticky_runners_spec.rb` — step injection, window tiers, max rule, expiry filtering, persist logic
- `spec/legion/llm/pipeline/steps/tool_history_spec.rb` — append, truncation, summarization, enrichment format
- `spec/legion/llm/pipeline/enrichment_injector_spec.rb` — history block injection
- `spec/legion/llm/conversation_store_spec.rb` — `store_metadata` with extra kwargs

---

## Not Included

- Per-tool stickiness (runner-level only)
- Compounding sticky windows (max rule only)
- DB-backed tool history (in-memory ConversationStore only for now — DB persistence follows the existing ConversationStore DB pattern and can be added later)
- UI changes to legion-interlink for displaying tool history
