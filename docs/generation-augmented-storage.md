# GAS: Generation-Augmented Storage

The exact conceptual inverse of [Retrieval-Augmented Generation (RAG)](https://en.wikipedia.org/wiki/Retrieval-augmented_generation).

## Deconstructing RAG

RAG solves one problem: models have stale, incomplete, static knowledge. At query time, you search a knowledge store, retrieve relevant chunks, inject them into the prompt, and generate a grounded answer. The direction is **Knowledge Store -> Model**, and it happens at **read time**.

| Aspect | RAG |
|--------|-----|
| Direction | Knowledge Store -> Model |
| Timing | Read-time (query-time, lazy, just-in-time) |
| Core action | PULL knowledge IN to improve output |
| Problem solved | Models have stale, incomplete, static knowledge |
| What it fixes | The model is dumb without external context |

## The Exact Inverse

Flip every axis simultaneously:

| Aspect | GAS |
|--------|-----|
| Direction | Model -> Knowledge Store |
| Timing | Write-time (ingest-time, eager, pre-computed) |
| Core action | PUSH reasoning OUT to improve storage |
| Problem solved | Knowledge stores are dumb, flat, disconnected |
| What it fixes | The storage is dumb without generative reasoning |

## Core Insight

**RAG's insight**: Don't cram all knowledge into the model. Keep it external and pull it in on demand.

**GAS's inverse insight**: Don't keep all reasoning locked inside the model. Push it out into the knowledge store proactively.

## How It Works

When new information arrives (a document, an event, a log, a message), instead of storing it raw and hoping retrieval finds it later, the system:

1. **Comprehends** -- The LLM reads and understands the incoming information
2. **Relates** -- Connects it to existing knowledge (implications, contradictions, dependencies)
3. **Synthesizes** -- Generates derivative knowledge that doesn't exist in the source (inferences, summaries, predictions, structured relationships)
4. **Deposits** -- Stores not just the raw fact but the pre-reasoned understanding of that fact

## The Symmetry

```
RAG:  Query -> Search -> Retrieve chunks -> Inject into prompt -> Generate answer
GAS:  Ingest -> Generate reasoning -> Extract structure -> Index into store -> Anticipate queries
```

RAG is **reactive**. You ask, it fetches, it answers.

GAS is **proactive**. Information arrives, it reasons, it pre-builds understanding.

## Why It's Equally Beneficial

RAG solved: "My model doesn't know enough."

GAS solves: "My knowledge base doesn't understand anything."

Today's vector databases store dumb chunks. They embed text, do cosine similarity, and return fragments. The retrieval side of RAG is glorified search. GAS makes the storage itself intelligent:

- Raw document goes in, structured knowledge graph comes out
- New fact arrives, contradictions with existing facts are flagged automatically
- Event is logged, implications and downstream effects are pre-computed
- The knowledge base **grows understanding**, not just volume

## The Compounding Effect

RAG has a linear relationship: better retrieval = better answers, one query at a time.

GAS has a **compounding** relationship: every new piece of information enriches everything already stored. The knowledge base gets smarter over time in a way that raw document stores never do. Fact 1,000 retroactively improves the context around facts 1-999.

## Convergence: GAS + RAG Together

The end state is both working in tandem:

```
Write path (GAS):  Data -> LLM comprehends -> Structured, reasoned, connected knowledge stored
Read path (RAG):   Query -> Retrieve pre-reasoned knowledge -> LLM generates grounded answer
```

- RAG without GAS = searching through dumb chunks
- GAS without RAG = smart storage nobody queries intelligently
- Both together = a knowledge system that understands what it stores and reasons about what it retrieves

## Comparison Table

| | RAG | GAS |
|---|---|---|
| When | Query time | Ingest time |
| Direction | Store -> Model | Model -> Store |
| Input trigger | User query | New information arriving |
| LLM role | Answer generator | Knowledge processor |
| Store role | Passive retrieval target | Active knowledge graph |
| Scaling | Linear (per-query) | Compounding (per-fact) |
| Failure mode | Bad retrieval = bad answer | Bad synthesis = bad knowledge |
| Cost profile | Per-query inference cost | Per-ingest inference cost |

## Implementation Considerations

### Write-Time Processing Pipeline

```
Raw Input
  |
  v
Comprehension Layer (LLM parses and understands)
  |
  v
Relation Layer (LLM connects to existing knowledge graph)
  |
  v
Synthesis Layer (LLM generates inferences, summaries, predictions)
  |
  v
Structured Deposit (knowledge graph updated with nodes + edges + reasoning)
```

### Key Design Decisions

- **Depth vs. latency**: How much reasoning to perform at ingest time vs. deferring to query time. Full GAS maximizes write-time reasoning; hybrid approaches balance the two.
- **Contradiction handling**: When new information contradicts existing knowledge, the system must resolve or flag the conflict, not silently overwrite.
- **Provenance tracking**: Every synthesized piece of knowledge must trace back to the source facts that produced it, preserving auditability.
- **Incremental re-reasoning**: When a foundational fact changes, downstream synthesized knowledge may need regeneration. Managing this cascade is the hardest engineering problem in GAS.

### Cost Tradeoffs

RAG pays inference cost at read time (per query). GAS pays inference cost at write time (per ingest). The bet GAS makes is that knowledge is written once and read many times, so front-loading the reasoning cost amortizes across all future reads. This mirrors the same tradeoff databases make with materialized views.

## Relationship to Apollo

In the LegionIO ecosystem, [lex-apollo](../../extensions-agentic/lex-apollo/) is the shared knowledge store where agents interact via RabbitMQ. Apollo's architecture naturally supports GAS: agents push structured, reasoned knowledge into pgvector-backed storage at event time, and the mesh collectively gets smarter with every interaction rather than just accumulating volume.

GAS provides the theoretical framework for why Apollo processes knowledge at write time rather than storing raw documents for later retrieval.
