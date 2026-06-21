---
title: LLM Gateway
nav_order: 3
description: "legion-llm: a universal LLM routing proxy with validated 86.8% context reduction, N×N any-to-any translation, mid-stream failover, and a 19-step governance pipeline."
---

# legion-llm: Universal LLM Gateway

{: .note }
**Summary:** Point any OpenAI- or Anthropic-compatible client at legion-llm and reach any backend — Anthropic, OpenAI, Bedrock, vLLM, Ollama, or a shared GPU fleet. 86.8% context reduction validated against actual wire-payload size. 3,200+ specs. Production-grade.

legion-llm is the LLM routing and execution layer inside LegionIO. It runs standalone as an LLM proxy or as the inference engine powering a full cognitive agent. Either way, the architecture is the same.

---

## The Core Architecture

Every request is parsed **once** into a canonical form, routed and executed, then rendered **once** back into the caller's dialect. No passthrough. No provider-name branching outside the translator layer.

```
┌───────────────────────────────┐     ┌─────────────────┐     ┌──────────────────────────┐
│ CLIENTS · any dialect         │     │ CANONICAL CORE  │     │ PROVIDERS · any backend  │
├───────────────────────────────┤     ├─────────────────┤     ├──────────────────────────┤
│ OpenAI    /v1/chat/completions│     │ parse once      │     │ Bedrock · Anthropic      │
│ OpenAI    /v1/responses       │ ──▶ │ route · execute │ ──▶ │ OpenAI · vLLM · Ollama   │
│ Anthropic /v1/messages        │     │ curate · meter  │     │ Fleet GPUs  (local = $0) │
└───────────────────────────────┘     └─────────────────┘     └──────────────────────────┘
```

A Claude Code session hitting `/v1/messages` can be served by a local vLLM backend running Gemma on an H200 — and never know the difference. The response comes back in Anthropic wire format, with correct streaming event types, translated from whatever the backend returned.

**This is N × N any-to-any.** N client dialects × N provider backends through one canonical core. Each provider's wire-format translation lives entirely inside its `lex-llm-*` gem. Nothing in the router, executor, or routes ever branches on a provider name.

---

## Drop-In Compatible

Change one `base_url`. Nothing else.

```python
# Python — OpenAI SDK
from openai import OpenAI
client = OpenAI(base_url="http://localhost:4567/v1", api_key="your-legion-key")
response = client.chat.completions.create(
    model="us.anthropic.claude-sonnet-4-6-v1",
    messages=[{"role": "user", "content": "Hello"}]
)
```

```python
# Python — Anthropic SDK
from anthropic import Anthropic
client = Anthropic(base_url="http://localhost:4567/v1", api_key="your-legion-key")
```

```bash
# Claude Code
ANTHROPIC_BASE_URL=http://localhost:4567 claude
```

```ruby
# Ruby
require 'legion/llm'
Legion::LLM.chat(message: "Hello")
```

---

## Validated Context Reduction

Long agentic sessions die by a thousand tokens. Every turn re-sends the full history, thinking blocks, and stale tool output. legion-llm's **Curator** runs asynchronously after each turn and keeps the payload bounded — validated against actual wire-payload size, not estimates.

**Across 29 turns, 8 real conversations:**

| | Without legion-llm | With legion-llm |
|---|---|---|
| Total tokens sent | 2,556,548 | 337,608 |
| **Reduction** | — | **86.8%** |

**Head-to-head: same 152-file PR review, Claude direct vs. Claude → legion-llm → local vLLM:**

| Metric | Claude direct (frontier) | Through legion-llm (local GPU) |
|---|---|---|
| Conversation context, turn 3 | 41.4K tokens, +7K/turn unbounded | 1.2K tokens, flat |
| Response time | 29s | 7s |
| Cost | Frontier API pricing | **$0** |
| Answer quality | Correct, specific | Correct, specific |

Both passed a multi-question recall test requiring context from earlier turns. On this class of task, the 86.8% reduction is not paid for in quality.

### How the Curator Works

The Curator (`Legion::LLM::Context::Curator`) runs async after each turn on a thread pool — zero latency added to in-flight requests. It composes deterministic strategies:

| Strategy | What it does |
|---|---|
| `strip_thinking` | Removes `<thinking>`/`<think>` blocks from prior turns (e.g. 69K chars → ~240) |
| `distill_tool_result` | Summarizes tool results over ~2K chars; type-aware (file reads, bash, search, JSON) |
| `fold_resolved_exchanges` | Collapses completed clarification exchanges to a single system note |
| `evict_superseded` | Drops a file read when a later read of the same file supersedes it |
| `dedup_similar` | Jaccard-similarity dedup at 0.85 threshold, window of 20 |
| `drop_and_archive` | Archives overflow to Apollo (knowledge store) rather than discarding it |

Preserved: the last N user turns (configurable) are always kept at full fidelity. The model retains complete context of recent work; only older turns are curated.

---

## Routing Architecture

Five tiers, automatic escalation, per-instance circuit breakers:

```
Tier 1: LOCAL   → Ollama on this machine (zero network, zero cost)
Tier 2: FLEET   → Shared GPU servers via AMQP (vLLM, Ollama fleet)
Tier 3: CLOUD   → Bedrock, Azure, Gemini
Tier 4: FRONTIER → Anthropic, OpenAI
```

**RANKING v2 lane weight formula:**
```
lane_weight = tier_weight × provider_weight × instance_weight × model_weight × health_multiplier
```

Health multiplier: `1.0` (closed circuit) → `0.5` (half-open) → excluded (open). All weights configurable at runtime with no restart.

**Intent-based routing:**

```ruby
# Route to local tier: strict privacy
llm_chat("Summarize this PII data", intent: { privacy: :strict })

# Route to frontier: hard reasoning task
llm_chat("Solve this proof", intent: { capability: :reasoning })

# Minimize cost: local/fleet preferred
llm_chat("Translate this paragraph", intent: { cost: :minimize })
```

**Local model discovery:** Before routing to a local model, legion-llm polls Ollama (`/api/tags`) and vLLM (`/v1/models`, `/health`), checks available system RAM (`/proc/meminfo` on Linux, `vm_stat` on macOS), and silently skips any model that isn't pulled or won't fit in memory. No silent OOM kills.

---

## True Execution Proxy

This is the contract that separates legion-llm from a passthrough:

**To the client**, legion-llm is a server-side execution surface: LegionIO-resolved tools run server-side and come back as results. The client never sees a pending action for a tool legion-llm already executed.

**To the provider**, legion-llm looks like the client: the same tool-use/tool-result exchange appears in the next turn in that provider's wire format, so the model always knows what happened.

This is verified on every test run by an in-process matrix harness that boots the real Sinatra app and replays the full client × provider × scenario matrix in ~250ms. The contract cannot silently regress.

---

## Mid-Stream Provider Failover

A provider outage during a streaming response does not kill the session. The `StreamAssembler` maintains one client SSE session while the canonical chunk source switches providers underneath. The client sees continuous output; the provider switch is invisible.

---

## Thinking Block Isolation

Reasoning/signatures/`redacted_thinking` survive same-provider replay. On any cross-provider transition (escalation, failover, tier swap), thinking is stripped. Signatures are provider-bound; foreign chain-of-thought is out-of-distribution.

This is enforced as a routing invariant — it's not a setting, it's a contract.

---

## How It Compares

| Capability | legion-llm | LiteLLM | OpenRouter |
|---|---|---|---|
| Architecture | Parse-once canonical core | Adapter/passthrough | Cloud proxy |
| Context curation | Built-in async (86.8% validated) | None | None |
| Conversation model | In-memory LRU + DB, branching, sidechains | Stateless | Stateless |
| Tool execution | Server-side execution proxy | Passthrough | Passthrough |
| Mid-stream failover | First-class (StreamAssembler) | Not supported | Not supported |
| Local model discovery | Native: Ollama + vLLM + RAM check | Manual config | Not applicable |
| Thinking block handling | Strips on cross-provider; preserves same-provider | Not handled | Not handled |
| Metering + audit | Every exit; AMQP events; distributed trace | Basic | Dashboard only |
| Self-hosted | Yes (local-first) | Yes | No (cloud) |
| Language | Ruby | Python | — |

---

## Providers

| Provider | Auth | Notes |
|---|---|---|
| AWS Bedrock | SigV4 or Bearer token | Default region us-east-2; supports cross-region inference profiles |
| Anthropic | API key or OAuth Bearer | Direct API; subscription OAuth passthrough supported |
| OpenAI | API key or OAuth Bearer | GPT models; Codex OAuth passthrough supported |
| Google Gemini | API key | Gemini models |
| Azure AI | API key or auth_token | Azure OpenAI endpoint |
| Ollama | None (local) | Auto-discovered; multi-instance; RAM-gated |
| vLLM | Optional API key | `/v1/models` + `/health` discovery; context window from `max_model_len` |
| MLX | Optional API key | Apple Silicon local inference |

Credentials resolve via a universal secret resolver: `vault://secret/path#key`, `env://VAR_NAME`, or plain strings. Array values act as fallback chains — first non-nil wins.

---

## Subscription OAuth Passthrough

legion-llm supports routing through a user's **Claude.ai subscription** or **OpenAI/Codex subscription** without requiring an API key — exactly as Headroom does, and using the same mechanism Anthropic explicitly designed for LLM gateways:

- `ANTHROPIC_AUTH_TOKEN` → sent as `Authorization: Bearer`, Anthropic's documented gateway auth path
- `CODEX_ACCESS_TOKEN` → ChatGPT/Codex OAuth token for OpenAI subscription routing

Since legion-llm runs locally (not as a remote server), the user's credentials never leave their machine. This is the same trust boundary as Claude Code itself.

---

## Compliance

Every pipeline exit emits metering + audit events:

- **Metering:** token counts, cost estimate, provider, model, duration — AMQP event to `llm.metering` exchange
- **Audit:** full distributed trace (trace_id, span_id, exchange_id), prompt content, tool calls — AMQP event to `llm.audit` exchange
- **PII/PHI classification:** patterns scanned before data leaves the network; classification level only upgrades, never downgrades
- **Budget enforcement:** per-session USD cap; request rejected before provider call if budget exceeded
- **Model policy:** `model_whitelist`/`model_blacklist` enforced at dispatch, fail-closed. Policy-denied models are terminal — never escalated, never trip circuits.

---

## Using legion-llm Standalone

legion-llm does not require the full LegionIO stack:

```bash
gem install legion-llm
```

```ruby
require 'legion/llm'

Legion::LLM.start
result = Legion::LLM.chat(message: "Hello")
puts result[:content]
```

The 19-step pipeline, routing, curator, and metering are all available. GAIA, Apollo, and RBAC steps degrade gracefully when not present.

---

## Source + Tests

- **Repository:** [github.com/LegionIO/legion-llm](https://github.com/LegionIO/legion-llm)
- **Test suite:** 3,200+ RSpec examples, 0 failures required
- **Matrix harness:** in-process Sinatra app, full client × provider × scenario replay in ~250ms per run
- **RuboCop:** 0 offenses enforced with `rubocop-legion` plugin

---

## Further Reading

- [19-Step Pipeline]({% link pipeline.md %}) — every step in detail
- [Architecture Overview]({% link architecture.md %}) — full system context
- [Settings Reference]({% link settings.md %}) — every configuration key
- [Enterprise Overview]({% link enterprise.md %}) — compliance, audit, cost recovery
