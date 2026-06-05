# legion-llm Agent Notes

## Scope

`legion-llm` provides provider configuration, chat/embed/structured interfaces, dynamic routing, escalation, quality checks, and pipeline execution for Legion.

## Fast Start

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## Primary Entry Points

- `lib/legion/llm.rb`
- `lib/legion/llm/providers.rb`
- `lib/legion/llm/router/`
- `lib/legion/llm/pipeline/`
- `lib/legion/llm/structured_output.rb`
- `lib/legion/llm/embeddings.rb`
- `lib/legion/llm/fleet/`

## Guardrails

- Keep typed error behavior and retry semantics stable (`ProviderDown`, `RateLimitError`, `EscalationExhausted`, etc.).
- Routing and escalation must remain deterministic given the same inputs/settings.
- Preserve pipeline feature-flag behavior; avoid forcing pipeline-only code paths.
- Keep provider credentials resolved through settings secret resolution flow; never hardcode secrets.
- Maintain compatibility with direct methods (`chat_direct`, `embed_direct`, `structured_direct`) and daemon-aware flows.
- Health tracker and rule scoring are contract-sensitive; changes require spec updates.

## Validation

- Run targeted specs for modified router/pipeline/provider code.
- Before handoff, run full `bundle exec rspec` and `bundle exec rubocop`.

---

## Client Request Headers Reference

Verified from source code (Claude Code binary + Codex `codex-rs` Rust source).

### Claude Code → `POST /v1/messages`

| Header | Value | Always? |
|---|---|---|
| `X-Claude-Code-Session-Id` | Stable UUID for the CLI session | Yes |
| `x-app` | `"cli"` (foreground) or `"cli-bg"` (background) | Yes |
| `x-claude-remote-session-id` | Remote container session ID | Conditional |
| `x-claude-remote-container-id` | Remote container ID | Conditional |
| `x-claude-code-agent-id` | Agent UUID for multi-agent sessions | Conditional |
| `x-claude-code-parent-agent-id` | Parent agent UUID (spawned subagent) | Conditional |
| `x-client-app` | Additional client app identifier | Conditional |

Conversation threading is **stateless** — full `messages[]` history sent in the body on every request. No conversation ID, turn ID, or `x-client-request-id` header is sent.

In Rack/Sinatra env keys, headers arrive as `HTTP_X_CLAUDE_CODE_SESSION_ID`, `HTTP_X_APP`, etc.

### Codex → `POST /v1/responses`

| Header | Value | Always? |
|---|---|---|
| `session-id` | Stable UUID for the Codex session | Yes |
| `thread-id` | Stable UUID for the thread/conversation | Yes |
| `x-client-request-id` | Same value as `thread-id` | Yes |
| `x-codex-installation-id` | Installation-scoped UUID | Yes |
| `x-codex-window-id` | `"{thread_id}:{window_generation}"` | Yes |
| `x-codex-turn-state` | Sticky-routing token returned by server, replayed by client | After first response |
| `x-codex-turn-metadata` | Per-turn observability metadata | Conditional |
| `x-codex-parent-thread-id` | Parent thread UUID (sub-agents) | Conditional |
| `x-openai-subagent` | Sub-agent type (`"review"`, `"compact"`, `"memory_consolidation"`, etc.) | Conditional |
| `x-openai-memgen-request` | `"true"` for memory generation requests | Conditional |

In Rack/Sinatra env keys: `HTTP_SESSION_ID`, `HTTP_THREAD_ID`, `HTTP_X_CLIENT_REQUEST_ID`, `HTTP_X_CODEX_INSTALLATION_ID`, etc.

**`HTTP_THREAD_ID` is the stable Codex thread/conversation ID** — it is stable for the lifetime of a thread, not per-request. `HTTP_X_CLIENT_REQUEST_ID` equals `HTTP_THREAD_ID` (Codex sets them to the same value).

Conversation threading over HTTP uses full input in body (stateless like Anthropic). Over WebSocket, `previous_response_id` is sent in the request body to enable delta-only input.

### Practical Usage in `/v1/messages` and `/v1/responses` Handlers

```ruby
# Stable request ID (Claude Code sends X-Claude-Code-Session-Id; Codex sends x-client-request-id = thread-id)
request_id = env['HTTP_X_CLIENT_REQUEST_ID'] || "req_#{SecureRandom.hex(12)}"

# Stable conversation/thread ID
# Claude Code: no header — generate per-request or use Legion conversation tracking
# Codex: HTTP_THREAD_ID is stable for the thread lifetime
conversation_id = env['HTTP_THREAD_ID'] ||
                  env['HTTP_X_LEGION_CONVERSATION_ID'] ||
                  body[:conversation_id] ||
                  "conv_#{SecureRandom.hex(8)}"

# Identify the calling client
claude_code_session = env['HTTP_X_CLAUDE_CODE_SESSION_ID']  # present only for Claude Code
codex_installation  = env['HTTP_X_CODEX_INSTALLATION_ID']   # present only for Codex
```
