# legion-llm — Agent Notes (v0.13.0)

`legion-llm` is a **universal translation proxy** for LLM traffic: N client dialects (OpenAI Chat,
OpenAI Responses, Anthropic Messages) × N provider backends (Bedrock, Anthropic, OpenAI, vLLM,
Ollama, fleet), any direction. Every request parses once into `Canonical::Request`, is
routed/executed, then renders once back to the caller's dialect. See `CLAUDE.md` for the full
invariant set; `README.md` for detailed reference.

## Fast Start

```bash
bundle install
bundle exec rspec      # 0 failures required before commit
bundle exec rubocop    # 0 offenses required
```

**The in-process matrix harness (`spec/legion/llm/api/matrix/`) is the commit gate.** Touch
`lib/legion/llm/api/`, the executor, or the canonical/translator boundary → it must pass before push.

## Primary Entry Points

- `lib/legion/llm.rb` — facade (`start`, `chat`, `ask`, `embed`, `structured`)
- `lib/legion/llm/inventory.rb` — **single source of truth** for the model catalog
- `lib/legion/llm/router.rb` + `router/{candidates,availability,health_tracker,escalation/}` — routing
- `lib/legion/llm/inference/executor.rb` + `executor/{routing,escalation}.rb` — pipeline
- `lib/legion/llm/inference/steps/` — the 18 pipeline steps
- `lib/legion/llm/api/{openai,anthropic,native}/` — client routes
- `lib/legion/llm/api/client_translators/` — canonical ↔ client wire formats
- `lib/legion/llm/context/curator.rb` — async conversation curation (context-cost control)
- Provider behaviour (defaults, capabilities, model filtering) lives in `../extensions-ai/lex-llm-*`

## Guardrails

- **Always translate, never passthrough**; **no `provider == :x` branches** outside translators.
- **Inventory is the only catalog**; `Discovery`/`Registry`/`HealthTracker` are feeders.
- Never dispatch a triple absent from the live catalog or unhealthy; **fail over, don't hard-fail**.
- **Model policy = compliance**: `model_whitelist`/`model_blacklist` honored at dispatch, fail-closed;
  a policy-denied model is terminal (never escalated, never trips circuits).
- Thinking never crosses providers; mid-stream failover must not kill an in-flight conversation.
- Every pipeline exit emits ledger events (metering/audit) — no bypasses.
- `Legion::JSON` only (symbol keys); every `rescue` re-raises or `handle_exception`s; no
  `defined?(Legion::Settings)` guards; `log.*` not `puts`.
- **No personal/company identifiers in VCS**; never force-push.
- Routing/escalation deterministic for the same inputs/settings; health-tracker & rule scoring are
  contract-sensitive — changes require spec updates.

## Validation

Run targeted specs for modified router/pipeline/translator code, then full `rspec` + `rubocop` +
the matrix harness before handoff.

---

## Client Request Headers Reference

Verified from source (Claude Code binary + Codex `codex-rs`). Useful when working on `/v1/messages`
and `/v1/responses` handlers. Routing/identity headers `X-Legion-{Provider,Model,Instance,Tier}` are
honored as **rules** (hard constraints), not hints.

### Claude Code → `POST /v1/messages`

| Header | Value | Always? |
|---|---|---|
| `X-Claude-Code-Session-Id` | Stable UUID for the CLI session | Yes |
| `x-app` | `"cli"` (foreground) or `"cli-bg"` (background) | Yes |
| `x-claude-code-agent-id` / `x-claude-code-parent-agent-id` | Agent / parent-agent UUIDs | Conditional |

Threading is **stateless** — full `messages[]` history in the body every request; no conversation/turn
ID header. In Rack env: `HTTP_X_CLAUDE_CODE_SESSION_ID`, `HTTP_X_APP`, etc.

### Codex → `POST /v1/responses`

| Header | Value | Always? |
|---|---|---|
| `session-id` | Stable UUID for the Codex session | Yes |
| `thread-id` | Stable UUID for the thread/conversation | Yes |
| `x-client-request-id` | Same value as `thread-id` | Yes |
| `x-codex-installation-id` | Installation-scoped UUID | Yes |
| `x-codex-turn-state` | Sticky-routing token, replayed by client | After first response |
| `x-openai-subagent` | Sub-agent type (`review`, `compact`, …) | Conditional |

`HTTP_THREAD_ID` is the stable thread/conversation ID (not per-request); `HTTP_X_CLIENT_REQUEST_ID`
equals it. HTTP threading is stateless (full input in body); over WebSocket, `previous_response_id`
enables delta-only input.

```ruby
request_id      = env['HTTP_X_CLIENT_REQUEST_ID'] || "req_#{SecureRandom.hex(12)}"
conversation_id = env['HTTP_THREAD_ID'] || env['HTTP_X_LEGION_CONVERSATION_ID'] ||
                  body[:conversation_id] || "conv_#{SecureRandom.hex(8)}"
```
