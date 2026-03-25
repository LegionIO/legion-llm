# GAS + Apollo: A Vision for Self-Reasoning Knowledge

**Companion to**: `generation-augmented-storage.md`
**Date**: 2026-03-23

## Executive Summary

Apollo already has the bones of GAS. Corroboration, confidence scoring, entity extraction, contradiction detection, graph traversal, expertise tracking, and GAIA tick integration are built. What's missing is the **continuous write-time reasoning pipeline** that transforms Apollo from a smart vector store into a self-reasoning knowledge graph. This document maps GAS onto every relevant Legion component and proposes a phased path to get there.

The thesis: Legion's competitive moat is not memory (commoditizing), not orchestration (crowded), but **a knowledge system that understands what it stores**. GAS is the theoretical framework. Apollo is the implementation. The rest of the stack (GAIA, Synapse, TBI, Transformer, LLM routing) already exists as the machinery to make it work.

---

## What Apollo Does Today

Apollo is a shared durable knowledge store. Agents publish knowledge via RabbitMQ; a dedicated service persists to PostgreSQL+pgvector.

### Existing Write-Time Intelligence

| Capability | How It Works | Where |
|---|---|---|
| Embedding generation | LLM embeds content at ingest | `Helpers::Embedding.generate` |
| Corroboration | Different agent writes similar knowledge (cosine > 0.9) -> confidence boost | `Knowledge.find_corroboration` |
| Source-aware weighting | Same provider = half weight, same channel = zero weight | `Knowledge.same_source_provider?` |
| Contradiction detection | Cosine > 0.7 + LLM structured judgment -> `disputed` status, `contradicts` relation | `Knowledge.detect_contradictions` |
| Entity extraction | LLM extracts person/service/repo/concept entities from text | `Runners::EntityExtractor` |
| Entity watchdog | Regex-based entity detection (pattern matching, no LLM) | `Helpers::EntityWatchdog` |
| Expertise tracking | Per-agent domain proficiency: `log2(count+1) * avg_confidence` | `Runners::Expertise`, `Knowledge.upsert_expertise` |
| Confidence decay | Hourly: power-law decay, archive stale entries | `Actors::Decay`, `Helpers::Confidence` |
| Retrieval boost | Accessed entries get +0.02 confidence | `Helpers::Confidence.apply_retrieval_boost` |
| GAIA publish gate | Only insights with confidence > 0.6 AND novelty > 0.3 reach Apollo | `GaiaIntegration.publishable?` |

### Existing Read-Time Intelligence

| Capability | How It Works | Where |
|---|---|---|
| Semantic search | pgvector cosine distance on embeddings | `Helpers::GraphQuery.build_semantic_search_sql` |
| Graph traversal | Recursive CTEs with spreading activation (factor 0.6) | `Helpers::GraphQuery.build_traversal_sql` |
| Domain isolation | Configurable access rules per knowledge domain | `Knowledge::DOMAIN_ISOLATION` |
| Status filtering | Only `confirmed` entries returned by default | `Knowledge.handle_query` |
| GAIA phase 4 | `knowledge_retrieval` fires when local memory lacks high-confidence matches | `Knowledge.retrieve_relevant` |

### What's Missing

Apollo stores knowledge and finds it. It does not **reason about** knowledge at write time beyond corroboration and contradiction. The entity extractor exists but doesn't create graph relations. The graph schema supports 8 relation types (`is_a`, `has_a`, `part_of`, `causes`, `similar_to`, `contradicts`, `supersedes`, `depends_on`) but only `similar_to` and `contradicts` are auto-created. There is no synthesis layer that generates derivative knowledge from inputs.

---

## The GAS-Enhanced Apollo Vision

### Data Flow: Before and After

**Today (RAG-oriented)**:
```
Agent generates insight
  -> GAIA phase 12 gate (confidence > 0.6, novelty > 0.3)
  -> RabbitMQ publish
  -> Apollo ingest: embed + corroboration scan + store
  -> Flat entry in apollo_entries with vector

Query arrives
  -> Embed query
  -> Cosine similarity search
  -> Return raw chunks with confidence scores
```

**GAS-enhanced**:
```
Information arrives (from ANY source: agent insight, webhook, document, event, log)
  -> RabbitMQ publish to apollo.ingest
  -> PHASE 1 - Comprehend: LLM parses input into structured facts
  -> PHASE 2 - Extract: Entity extraction + type classification
  -> PHASE 3 - Relate: LLM connects to existing graph (all 8 relation types)
  -> PHASE 4 - Synthesize: LLM generates implications, predictions, summaries
  -> PHASE 5 - Deposit: Store original + derived entries + relations + entities
  -> PHASE 6 - Anticipate: Pre-compute likely queries this knowledge answers

Query arrives
  -> Check anticipation cache (Tier 0: no LLM, instant)
  -> If miss: embed query, graph-aware search (traversal + semantic hybrid)
  -> Return pre-reasoned knowledge with provenance chains
```

### The Six GAS Phases in Detail

#### Phase 1: Comprehend

The LLM reads raw input and produces structured output. This is where unstructured text becomes typed knowledge.

**Input**: Raw text content from any source.

**Output**: Structured fact set with classified `content_type` values.

**Existing infrastructure**:
- `lex-transformer` LLM engine can do this transformation today
- Apollo's `content_type` field already supports: `fact`, `concept`, `procedure`, `association`, `observation`
- `lex-transformer` definitions (Settings-based) can store reusable comprehension prompts

**What to build**:
- A comprehension transform definition in Settings that converts raw text into one or more typed entries
- Multi-fact extraction: one input document may yield N separate knowledge entries (transformer fan-out already supports this via array dispatch)

**Example**:
```
Input:  "The Grid uses Consul for service discovery and Vault for secrets management.
         Both run on Azure VMs provisioned by Terraform."

Output: [
  { content_type: :fact, content: "The Grid uses Consul for service discovery" },
  { content_type: :fact, content: "The Grid uses Vault for secrets management" },
  { content_type: :fact, content: "Consul and Vault run on Azure VMs" },
  { content_type: :procedure, content: "Azure VMs are provisioned by Terraform" },
  { content_type: :association, content: "Consul and Vault are co-deployed on Grid infrastructure" }
]
```

#### Phase 2: Extract

Identify named entities and classify them. This is already mostly built.

**Existing infrastructure**:
- `Runners::EntityExtractor` uses `Legion::LLM.structured` to pull entities with confidence scores
- `Helpers::EntityWatchdog` does fast regex detection for `person`, `service`, `repo`, `concept`
- Entity types are configurable via Settings

**What to build**:
- Wire entity extraction results INTO the graph. Today `EntityExtractor` returns entities but nothing creates Apollo entries or relations from them.
- `EntityWatchdog.link_or_create` has the skeleton (`find_existing`, `create_candidate`, `bump_confidence`) but the methods are stubs. Implement them.
- Create `entity` as a knowledge domain with its own entries. Entities become first-class graph nodes, not just annotations.

#### Phase 3: Relate

The most important GAS phase. The LLM examines existing knowledge and creates typed relations between the new entry and existing entries.

**Existing infrastructure**:
- `apollo_relations` table with `from_entry_id`, `to_entry_id`, `relation_type`, `source_agent`, `weight`
- `Helpers::Confidence::RELATION_TYPES` already defines all 8 types: `is_a`, `has_a`, `part_of`, `causes`, `similar_to`, `contradicts`, `supersedes`, `depends_on`
- `Helpers::GraphQuery.build_traversal_sql` already traverses these relations with spreading activation
- Contradiction detection already creates `contradicts` relations via LLM judgment

**What to build**:
- A relation discovery step in `handle_ingest` that:
  1. Retrieves the top-N most semantically similar existing entries (already done for corroboration)
  2. For each similar entry, asks the LLM to classify the relationship type
  3. Creates `apollo_relations` entries with appropriate weights
- This is the same pattern as `llm_detects_conflict?` but generalized to all 8 relation types
- Use `Legion::LLM.structured` with a schema that returns `{ relation_type: string, confidence: float, reasoning: string }`
- Gate behind a configurable threshold: only create relations when LLM confidence > 0.7

**Example**: New entry "Consul uses Raft consensus for leader election" arrives.
- Existing entry: "The Grid uses Consul for service discovery"
- LLM classifies: `{ relation_type: "part_of", confidence: 0.85, reasoning: "Raft consensus is a component of Consul" }`
- Creates relation: `from: new_entry, to: existing_entry, relation_type: "part_of", weight: 0.85`

#### Phase 4: Synthesize

The LLM generates NEW knowledge that doesn't exist in the source input but is implied by it in combination with existing knowledge. This is where the compounding effect comes from.

**Existing infrastructure**:
- Apollo can store synthesis results as entries with `content_type: :association` or `:concept`
- `depends_on` relation type links synthesized knowledge back to source entries
- Corroboration model means synthesis entries start as `candidate` and must be independently confirmed

**What to build**:
- A synthesis step that examines the new entry + its newly-created relations + the related entries, and asks: "What can we now infer that we couldn't before?"
- Synthesis entries are marked with a special tag (e.g., `synthesized`) and `depends_on` relations to all source entries
- Synthesis confidence is the geometric mean of source entry confidences, capped at 0.7 (can never exceed its sources without independent corroboration)
- Critical safety: synthesis entries start as `candidate`. They need corroboration from a different agent to become `confirmed`. This prevents hallucination cascading.
- Use `lex-transformer` definitions for reusable synthesis prompts per domain

**Example**: After relating "Consul uses Raft consensus" to "The Grid uses Consul":
- Synthesis: "Grid service discovery depends on Raft consensus availability" (content_type: `:association`)
- This entry is `candidate` until another agent independently corroborates it
- `depends_on` relations link it to both source entries

#### Phase 5: Deposit

Store everything produced by phases 1-4. This is largely what `handle_ingest` already does, extended to handle batch entry creation with relations.

**Existing infrastructure**:
- `handle_ingest` creates entries, embeddings, corroboration checks, expertise tracking, access logging
- All the Sequel models exist: `ApolloEntry`, `ApolloRelation`, `ApolloExpertise`, `ApolloAccessLog`

**What to build**:
- Batch ingest: one raw input may produce N entries (comprehension) + M relations (relate) + K synthesis entries
- Transaction wrapping: all entries from one ingest should succeed or fail atomically
- Provenance tracking: a `source_ingest_id` field (or similar) linking all entries back to the original raw input

#### Phase 6: Anticipate

Pre-compute answers to likely queries. This is where GAS meets TBI.

**Existing infrastructure**:
- TBI's Tier 0 pattern cache (PatternStore in `legion-mcp`): L0 in-memory, L1 cache, L2 local SQLite
- TBI's confidence model: seeded 0.5, +0.02 hit, -0.05 miss
- TBI's TierRouter: confidence >= 0.8 = Tier 0 (no LLM, instant)

**What to build**:
- After deposit, the system generates 1-3 likely questions this knowledge would answer
- Pre-computes an answer using the graph (not just the entry, but the entry + its relations + synthesis)
- Stores in TBI's PatternStore as pre-cached responses
- When a query matches a pattern, it returns the pre-computed answer with zero LLM cost
- This is the "just-in-time learning" from TBI applied to knowledge retrieval

---

## How Every Legion Component Fits

### legion-llm: The Reasoning Engine

legion-llm is the muscle behind every GAS phase. The routing engine determines WHERE reasoning happens (local vs fleet vs cloud). The cost profile shifts from per-query to per-ingest.

| GAS Phase | LLM Operation | Routing Intent |
|---|---|---|
| Comprehend | `structured` (text -> typed facts) | `{ capability: :moderate, cost: :normal }` |
| Extract | `structured` (entity extraction) | `{ capability: :basic, cost: :minimize }` |
| Relate | `structured` (relation classification) | `{ capability: :moderate, cost: :normal }` |
| Synthesize | `chat` (open-ended reasoning) | `{ capability: :reasoning, cost: :normal }` |
| Anticipate | `chat` (question generation) | `{ capability: :basic, cost: :minimize }` |

The escalation chain applies per-phase: if local model can't extract entities well, escalate to fleet or cloud. QualityChecker validates outputs at each phase.

**Key optimization**: Comprehend/Extract/Relate can often use smaller models (Tier 1 local). Only Synthesize consistently needs frontier models (Tier 2 cloud). As TBI observes successful patterns, routine comprehension/extraction drops to Tier 0 (no model at all).

### GAIA: The Tick Cycle Integration

GAIA already has the hooks. GAS extends them.

**Current GAIA phases relevant to GAS**:
- Phase 4 `knowledge_retrieval`: Queries Apollo. With GAS, this returns pre-reasoned knowledge instead of raw chunks.
- Phase 12 `post_tick_reflection`: Writes insights to Apollo. With GAS, the ingest pipeline processes these insights through all six phases.

**New GAIA integration points**:
- **Proactive ingestion**: GAIA can push external signals (webhook payloads, Teams messages, document changes) directly into Apollo's GAS pipeline, not just tick insights.
- **Dream-time synthesis**: During the dream cycle (`dormant_active` mode), GAIA can trigger synthesis across accumulated daily knowledge. The dream cycle's 8 phases already consolidate memory -- GAS adds knowledge consolidation.
  - Dream phase runs Apollo synthesis on entries accumulated since last dream
  - Identifies clusters of related entries that haven't been explicitly linked
  - Generates new synthesis entries connecting them
  - This is "sleeping on it" -- the system literally processes knowledge overnight

### lex-synapse: Routing Knowledge Through Comprehension

Synapse routes tasks with confidence-scored intelligence. GAS creates a new class of task chains: **comprehension routes**.

**How it works**:
1. Raw input arrives at Apollo ingest queue
2. Synapse wraps the ingest pipeline as a task chain: `raw_input -> comprehend -> extract -> relate -> synthesize -> deposit`
3. Each step is a Synapse-managed relationship with its own confidence score
4. If the comprehension route consistently produces good knowledge (corroborated, not contradicted), confidence rises toward AUTONOMOUS
5. At AUTONOMOUS level, Synapse can self-modify the comprehension templates (via mutation + adversarial challenge)
6. When comprehension patterns stabilize, TBI caches them at Tier 0

**The learning loop**:
```
Ingest -> Synapse routes through GAS phases -> Knowledge deposited
                                                      |
                                              Later queried & used?
                                                  /          \
                                                yes            no
                                                /                \
                                    Synapse confidence +0.02    Decay cycle
                                    Route strengthens           Route weakens
                                    Phases optimize             Eventually archived
```

This means the system learns WHICH kinds of knowledge benefit from deep GAS processing and which can be stored with lighter treatment. Not every ingest needs all six phases. Synapse learns the routing.

### lex-transformer: The Template Engine for GAS

Transformer already has an LLM engine. GAS uses named transform definitions for each phase.

**Example definitions** (in Settings):
```json
{
  "lex_transformer": {
    "definitions": {
      "gas_comprehend": {
        "engine": "llm",
        "transformation": "Extract structured facts from this text. For each fact, classify as: fact, concept, procedure, association, or observation. Return a JSON array.",
        "engine_options": { "model": null, "intent": { "capability": "moderate" } },
        "schema": { "required_keys": ["facts"], "types": { "facts": "Array" } }
      },
      "gas_relate": {
        "engine": "llm",
        "transformation": "Given the new entry and these existing entries, classify the relationship type for each pair: is_a, has_a, part_of, causes, similar_to, contradicts, supersedes, depends_on. Return JSON.",
        "engine_options": { "intent": { "capability": "moderate" } }
      },
      "gas_synthesize": {
        "engine": "llm",
        "transformation": "Given these related facts, what new knowledge can be inferred that is not explicitly stated? Return only high-confidence inferences.",
        "engine_options": { "intent": { "capability": "reasoning" } }
      }
    }
  }
}
```

**Transform chains** execute the GAS phases sequentially: `comprehend -> extract -> relate -> synthesize`. Output of each phase feeds the next. Transformer already supports this via `transform_chain(steps:)`.

### TBI: The Convergence Point

TBI's design backlog item (#7) says:

> "The LLM is a teacher, not a servant. It teaches the system patterns. Once learned, the LLM is no longer needed for those patterns."

GAS says:

> "Push reasoning into the knowledge store. The knowledge base gets smarter over time."

These are the same insight. TBI teaches the SYSTEM patterns. GAS teaches the KNOWLEDGE patterns. Together:

```
                    TBI                                    GAS
              (system learns)                      (knowledge learns)
                    |                                       |
         Observe tool usage                     Observe knowledge ingestion
         Learn routing patterns                 Learn comprehension patterns
         Cache at Tier 0                        Cache at Tier 0
         LLM no longer needed                   LLM no longer needed
         for routine operations                 for routine knowledge
                    |                                       |
                    +----------- CONVERGENCE ---------------+
                    |                                       |
              System knows HOW                    Knowledge knows WHAT
              to do things                        things mean
```

**Concrete convergence**: When a query arrives:
1. TBI checks: "Have I seen this query pattern before?" (Tier 0 tool pattern cache)
2. GAS checks: "Has this knowledge already been pre-reasoned?" (Tier 0 anticipation cache)
3. If both hit: zero LLM cost. System knows what to do AND has the answer ready.
4. If either misses: escalate to Tier 1/2, but LEARN from the result for next time.

### lex-metering: The Cost Model

RAG costs are per-query. GAS costs are per-ingest. The economic bet:

```
Cost_RAG = N_queries * cost_per_query

Cost_GAS = N_ingests * cost_per_ingest + N_queries * cost_per_lookup
           (where cost_per_lookup << cost_per_query because answers are pre-reasoned)

Break-even when: N_queries/N_ingests > cost_per_ingest/cost_per_query
```

Knowledge is written once and read many times. For any knowledge that gets queried more than once, GAS wins. For knowledge that's never queried, GAS overpaid. Synapse confidence routing naturally handles this: low-value knowledge sources get lighter GAS processing over time.

**Metering integration**:
- Tag ingest costs as `gas.comprehend`, `gas.extract`, `gas.relate`, `gas.synthesize`
- Tag query costs as `gas.query` vs `gas.tier0_hit`
- Dashboard shows: ingest cost trend, query cost trend, Tier 0 hit rate, cost-per-useful-knowledge-entry
- When Tier 0 hit rate exceeds 80%, the system is paying almost nothing for queries

### lex-mesh: Distributed GAS

When multiple agents are connected via mesh:
- Each agent pushes knowledge through its local GAS pipeline
- Apollo corroboration model ensures multi-agent validation
- Expertise tracking knows WHICH agents produce reliable knowledge in which domains
- Mesh departure handler (`GaiaIntegration.handle_mesh_departure`) triggers knowledge redistribution

**GAS enhancement to mesh**: Agents specialize in comprehension domains. Agent A might be excellent at comprehending infrastructure knowledge (high Synapse confidence on infrastructure GAS routes). Agent B might be excellent at code knowledge. The mesh naturally routes ingestion to the best comprehender via expertise tracking.

### lex-dream + lex-reflection: Overnight Knowledge Consolidation

The dream cycle already consolidates memory traces. GAS extends this to knowledge:

**Dream-time GAS operations** (new, during `dormant_active` tick mode):
1. **Merge**: Find clusters of similar entries (cosine > 0.85) that aren't explicitly related. Create `similar_to` relations.
2. **Strengthen**: Entries accessed many times but still `candidate` get reviewed for promotion.
3. **Prune**: Synthesis entries whose source entries have been archived get re-evaluated.
4. **Cross-pollinate**: Entries from different knowledge domains that share entities get new `causes` or `depends_on` relations.
5. **Summarize**: Long chains of related entries get a summary synthesis entry at the cluster level.

lex-reflection's post-tick insights already feed Apollo. With GAS, reflection outputs go through full comprehension rather than being stored as raw text.

### The Agentic Extensions: Cognitive GAS

The 13 consolidated agentic domain gems map naturally to GAS:

| Domain | GAS Role |
|---|---|
| `lex-agentic-inference` | Bayesian reasoning during Synthesize phase. Belief updating when contradictions detected. |
| `lex-agentic-memory` | Local memory cache of recently ingested/queried knowledge. Reduces Apollo round-trips. |
| `lex-agentic-learning` | Reinforcement learning on GAS pipeline effectiveness. Which comprehension patterns work? |
| `lex-agentic-attention` | Salience filtering on ingest. Not all inputs deserve full GAS processing. |
| `lex-agentic-executive` | Working memory integration of GAS results into active reasoning. |
| `lex-agentic-defense` | Hallucination detection on synthesis outputs. Bias monitoring on relation classification. |
| `lex-agentic-integration` | Cross-modal binding when knowledge comes from different channels (Teams, webhook, CLI). |

---

## The Compounding Flywheel

This is the property that makes GAS as beneficial as RAG. Each piece reinforces the others:

```
More knowledge ingested
      |
      v
More relations discovered (Phase 3)
      |
      v
Richer graph for synthesis (Phase 4)
      |
      v
Better synthesis quality (new inferences connect old knowledge)
      |
      v
More pre-computed answers (Phase 6)
      |
      v
Higher Tier 0 hit rate (cheaper queries)
      |
      v
More budget for ingestion (cost shifts from query to ingest)
      |
      v
More knowledge ingested  <-- flywheel
```

**Retroactive enrichment**: When fact #1000 arrives and connects to fact #47 and fact #823, synthesis may produce a new insight that ALSO connects to facts #200-#210. Those facts retroactively become more useful. Their confidence rises (retrieval boost), their relations grow, and the graph neighborhood becomes denser. This doesn't happen in RAG. In RAG, fact #47 is just a chunk that sits there. In GAS, fact #47 participates in a living graph that grows smarter every day.

---

## What Exists vs What Needs Building

### Already Built (use as-is)

- [x] Apollo entry model with confidence, status, content_type, knowledge_domain
- [x] Apollo relations model with all 8 relation types
- [x] Apollo expertise tracking with log2-weighted proficiency
- [x] Corroboration model (cosine > 0.9, multi-agent validation, source-aware weighting)
- [x] Contradiction detection via LLM structured judgment
- [x] Entity extraction via LLM structured output
- [x] Entity watchdog pattern matching
- [x] Graph traversal via recursive CTEs with spreading activation
- [x] Semantic search via pgvector cosine distance
- [x] GAIA phase 4 (knowledge retrieval) and phase 12 (post-tick reflection)
- [x] GAIA publish gate (confidence > 0.6, novelty > 0.3)
- [x] lex-transformer LLM engine with named definitions and transform chains
- [x] lex-synapse confidence routing with proposals and adversarial challenges
- [x] TBI Tier 0 pattern cache (PatternStore, TierRouter, ContextGuard)
- [x] legion-llm routing engine with intent-based dispatch and escalation
- [x] lex-metering cost attribution per task
- [x] Confidence decay cycle (hourly, power-law)
- [x] Domain isolation for access control

### Needs Building (ordered by dependency)

**Phase A: Wire existing pieces together**
- [ ] `EntityWatchdog.link_or_create` stubs -> implement `find_existing` and `create_candidate`
- [ ] Entity extraction results -> auto-create Apollo entries + `is_a` relations to entity type nodes
- [ ] `handle_ingest` -> call entity extraction after embedding generation
- [ ] Comprehension transform definition in Settings (reusable LLM prompt for `gas_comprehend`)

**Phase B: Relation discovery**
- [ ] Generalize `llm_detects_conflict?` to `llm_classify_relation?` covering all 8 relation types
- [ ] Add relation discovery step to `handle_ingest` after corroboration check
- [ ] Use `Legion::LLM.structured` with relation schema
- [ ] Configurable threshold: only create relations when LLM confidence > 0.7
- [ ] Batch create relations within the same DB transaction as entry creation

**Phase C: Synthesis layer**
- [ ] New `Runners::Synthesize` module in lex-apollo
- [ ] After relation discovery, collect new_entry + related_entries, prompt LLM for inferences
- [ ] Store synthesis entries as `content_type: :association`, status: `candidate`, tagged `synthesized`
- [ ] Create `depends_on` relations from synthesis to all source entries
- [ ] Synthesis confidence = geometric mean of source confidences, capped at 0.7
- [ ] GAIA dream-time synthesis: batch process day's accumulated entries

**Phase D: Anticipation cache**
- [ ] After deposit, generate 1-3 likely questions via LLM
- [ ] Pre-compute answers using graph-aware retrieval
- [ ] Store in TBI PatternStore as pre-cached responses
- [ ] Wire into `handle_query`: check anticipation cache before semantic search

**Phase E: Synapse-managed GAS routes**
- [ ] Model the GAS pipeline as a Synapse task chain
- [ ] Synapse confidence per-phase: learn which inputs need which phases
- [ ] Attention filtering on ingest (not all inputs need full 6-phase processing)
- [ ] Adaptive depth: high-value domains get full GAS, low-value get light treatment

**Phase F: Dream-time consolidation**
- [ ] Dream cycle hook: merge similar un-related entries
- [ ] Dream cycle hook: cross-domain relation discovery
- [ ] Dream cycle hook: cluster summarization
- [ ] Dream cycle hook: prune orphaned synthesis entries

---

## Cost Projections

Rough per-entry estimates (using Bedrock Sonnet pricing as baseline):

| Phase | Tokens In | Tokens Out | Cost/Entry |
|---|---|---|---|
| Comprehend | ~500 | ~200 | ~$0.003 |
| Extract | ~400 | ~150 | ~$0.002 |
| Relate (per relation) | ~600 | ~100 | ~$0.003 |
| Synthesize | ~800 | ~300 | ~$0.005 |
| Anticipate | ~400 | ~200 | ~$0.003 |
| **Total (full GAS)** | | | **~$0.016/entry** |

Compare to per-query RAG cost (embed + generate): ~$0.005/query.

**Break-even**: If each knowledge entry is queried 4+ times, GAS pays for itself. For frequently-accessed knowledge (procedures, architecture facts, common Q&A), the ratio is far higher.

**TBI acceleration**: As patterns stabilize:
- Comprehend drops to Tier 1 (local): ~$0.001 -> $0.000
- Extract drops to Tier 0 (cached): $0.000
- Relate drops to Tier 1: ~$0.001 -> $0.000
- Only Synthesize consistently stays at Tier 2

Mature GAS cost per entry: **~$0.005** (synthesis only). With Tier 0 query hits, total cost converges toward zero for routine knowledge.

---

## Why This Is Legion's Moat

Everyone is building RAG. Vector stores are commoditized. The retrieval side is solved -- cosine similarity works, chunk-and-retrieve works, hybrid search works.

Nobody is building GAS. Nobody is pushing reasoning INTO the knowledge store at write time. Nobody has the infrastructure to do it: you need an LLM routing engine (legion-llm), a confidence-scored task router (lex-synapse), a behavioral learning system (TBI), a cognitive tick cycle (GAIA), a multi-agent corroboration model (Apollo), AND a template-driven transformation engine (lex-transformer) -- all working together.

Legion has all of these. They're built. They're tested. They just need to be wired into this pipeline.

The competitive position isn't "we have better retrieval." It's "our knowledge base understands what it stores, and it gets smarter every day without human intervention." That's a fundamentally different value proposition, and it compounds in a way that RAG-only systems can't match.
