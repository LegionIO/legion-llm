---
title: Home
layout: home
nav_order: 1
description: "Local-first AI agent platform: universal LLM proxy with 86.8% validated context reduction, cognitive agent runtime, and 73 extension gems."
---

<div class="hero-section">
  <iframe src="{{ '/assets/visualization.html' | relative_url }}" title="LegionIO cognitive architecture visualization" loading="eager"></iframe>
  <div class="hero-overlay">
    <h1>LegionIO</h1>
    <p class="hero-tagline">What if your AI agent had a brain &mdash; not just a prompt?</p>
    <p class="hero-stats">73 extension gems &middot; 60 MCP tools &middot; 86.8% context reduction &middot; 23,000+ specs</p>
    <div class="hero-install">
      <span class="hero-prompt">$ </span>gem install legionio
    </div>
    <div class="hero-cta">
      <a href="{% link getting-started/quickstart-agent.md %}" class="hero-primary">See It Think</a>
      <a href="{% link architecture.md %}" class="hero-secondary">How It Works</a>
      <a href="{% link philosophy.md %}" class="hero-secondary">Why We Built This</a>
    </div>
  </div>
  <div class="hero-motto">Too lazy for prompts. Built a brain instead.</div>
</div>

---

## Start Here

Pick your path — each one gets you to an "aha" moment in 15 minutes or less.

| You are... | Start with... | Time |
|:-----------|:-------------|:-----|
| **An AI/agent builder** | [Cognitive Agent Quickstart]({% link getting-started/quickstart-agent.md %}) | 15 min |
| **A Ruby developer** | [Extension Dev Quickstart]({% link getting-started/quickstart-ruby.md %}) | 10 min |
| **An LLM power user** | [LLM Gateway Deep-Dive]({% link llm-gateway.md %}) | 10 min |
| **Evaluating for enterprise** | [Enterprise Overview]({% link enterprise.md %}) | 5 min read |
| **Ready to contribute** | [Contributing Guide](https://github.com/LegionIO/.github/blob/main/CONTRIBUTING.md) | 5 min read |

---

## The LLM Gateway

legion-llm is a **universal translation proxy** for LLM traffic — a standalone gem that also powers the full agent stack. Point any OpenAI- or Anthropic-compatible client at it and reach any backend.

**Validated numbers** (actual wire-payload size, not estimates):

| | Without | With legion-llm |
|---|---|---|
| Tokens sent across 29 turns | 2,556,548 | 337,608 — **86.8% less** |
| Context at turn 3, same PR review | 41.4K growing | **1.2K flat** |
| Response time | 29s (frontier) | **7s (local GPU)** |
| Cost | Frontier pricing | **$0** |

Any client, any provider, every direction — N × N through one canonical core. The 86.8% reduction comes from the **Curator**: an async post-turn processor that strips thinking blocks, distills tool results, folds resolved exchanges, evicts superseded file reads, and archives overflow to the knowledge store. It runs after each turn on a thread pool, adding zero latency to in-flight requests.

[LLM Gateway Deep-Dive →]({% link llm-gateway.md %})

---

## The Cognitive Stack

Every LegionIO agent runs a **tick cycle** — a 24-phase cognitive loop modeled on biological neural processing. 16 active phases run each tick: the agent perceives, remembers, predicts, decides, acts, and reflects. During idle periods, an 8-phase **dream cycle** consolidates memory, resolves contradictions, and forms new agendas.

```mermaid
flowchart LR
    subgraph TICK["Waking Tick Cycle"]
        direction LR
        A["Sensory\nProcessing"] --> B["Emotional\nEvaluation"]
        B --> C["Memory\nRetrieval"]
        C --> D["Knowledge\nRetrieval"]
        D --> E["Identity\nEntropy Check"]
        E --> F["Working Memory\nIntegration"]
        F --> G["Procedural\nCheck"]
        G --> H["Prediction\nEngine"]
        H --> I["Mesh\nInterface"]
        I --> N["Social\nCognition"]
        N --> O["Theory of\nMind"]
        O --> J["Gut\nInstinct"]
        J --> K["Action\nSelection"]
        K --> L["Memory\nConsolidation"]
        L --> P["Homeostasis\nRegulation"]
        P --> M["Post-Tick\nReflection"]
    end

    subgraph DREAM["Dream Cycle"]
        direction LR
        D1["Memory\nAudit"] --> D2["Association\nWalk"]
        D2 --> D3["Contradiction\nResolution"]
        D3 --> D4["Agenda\nFormation"]
        D4 --> D5["Consolidation\nCommit"]
        D5 --> D9["Knowledge\nPromotion"]
        D9 --> D6["Dream\nReflection"]
        D6 --> D7["Dream\nNarration"]
    end
```

234 cognitive modules across 13 domain gems — memory, emotion, attention, inference, social cognition, metacognition, imagination, and more. Every module is optional, composable, and independently removable.

[Architecture Overview]({% link architecture.md %}) | [Philosophy]({% link philosophy.md %})

---

## The LLM Pipeline

Every LLM call runs through a **19-step governance pipeline** — not just "call the model." RBAC enforcement, PII/PHI classification, RAG context injection, budget guards, tool dispatch, knowledge capture, confidence scoring, and full audit trail. Every step is optional, composable, and independently removable.

[Pipeline Deep-Dive]({% link pipeline.md %})

---

## See It in Action

<!-- TODO: Replace with asciinema embed or gif after recording (Task 2 from catalyst plan) -->

```
$ legion start
  73 extensions loaded
  Tick cycle: 16 phases active, 8 dream phases standby
  Dream cycle: standby
  API: http://localhost:4567
  Ready.

$ legion chat
  You: Tell me about yourself
  Agent: I'm a LegionIO cognitive agent. I have memory that fades,
         predictions that adapt, and I dream during idle periods
         to consolidate what I've learned. What would you like
         to explore?
```

*45 seconds from install to your first conversation with an agent that thinks.*

---

## Community

- [GitHub Discussions](https://github.com/LegionIO/docs/discussions) — questions, ideas, architecture talk
- [Slack](https://legionio.slack.com) — real-time chat
- [Philosophy]({% link philosophy.md %}) — understand our design principles before contributing
- [Extension Catalog]({% link extensions.md %}) — browse all 73 extensions

---

## Quick Install

```bash
# Homebrew (recommended)
brew tap LegionIO/tap
brew install legionio

# Or RubyGems
gem install legionio

# Start the engine
legion start

# Or just chat
legion chat

```

**Requirements:** Ruby >= 3.4, RabbitMQ. Optional: PostgreSQL/MySQL/SQLite, Redis/Memcached, HashiCorp Vault.

---

**License:** Core framework [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) | Extensions [MIT](https://opensource.org/licenses/MIT)
