# Context Curation: Production Metrics

Aggregate metrics from a production LegionIO deployment, exported from
[lex-llm-ledger](https://github.com/LegionIO/lex-llm-ledger) — the audit ledger that
records every LLM request the framework makes. All requests over the measurement
window, bucketed by conversation length. Nothing filtered, nothing excluded.

**The honest headline:** curation saves approximately nothing on short conversations
and ~98% on long agent sessions — and that asymmetry is the point, because that's
where the cost lives. In this window, 97.8% of all would-be tokens came from the 50+
turn bucket, while 99% of conversations by count were single-turn and gained nothing
(-0.1%, the overhead is noise). Curation doesn't make cheap traffic cheaper; it
prevents the runaway sessions that dominate spend.

## Baseline definition (read before quoting any percentage)

"Naive" means: no client-side context management at all — the full accumulated
conversation resent on every turn. That is the default behavior of a plain agent loop,
but it is a worst-case counterfactual, not a claim about what your current tooling
does. A client that already trims context will see smaller deltas. All percentages
below use this single denominator: `actually_sent / naive_would_have_sent`.

## Savings vs. naive resend, by conversation length

| Turns in conversation | 1 | 2–3 | 4–5 | 6–9 | 10–19 | 20–49 | 50+ |
|---|---|---|---|---|---|---|---|
| Total requests | 126,202 | 1,941 | 299 | 343 | 559 | 826 | 10,956 |
| Conversations | 126,202 | 947 | 69 | 50 | 43 | 29 | 37 |
| Avg turns/conversation | 1 | 2 | 4.3 | 6.9 | 13 | 28.5 | 296.1 |
| Naive would have sent (tokens) | 163.4M | 2.59M | 4.00M | 6.65M | 28.2M | 74.4M | 12.35B |
| Actually sent (tokens) | 163.6M | 2.35M | 3.47M | 5.08M | 12.9M | 20.3M | 285.6M |
| Avg naive per turn | 1,295 | 1,336 | 13,382 | 19,376 | 50,360 | 90,019 | 1,127,381 |
| Avg actual per turn | 1,296 | 1,208 | 11,607 | 14,812 | 22,998 | 24,521 | 26,064 |
| **Reduction vs. naive** | **-0.1%** | **9.6%** | **13.3%** | **23.6%** | **54.3%** | **72.8%** | **97.7%** |

The mechanism is visible in the per-turn averages: in the 50+ bucket (dominated by
long-running agent sessions averaging 296 turns), naive resend grows unbounded toward
1.13M tokens per turn while curated context stays flat around 26K. Bounded per-turn
context is the claim this table proves; percentage reductions are a consequence of it.

Token-weighted across all buckets the reduction is ~96%, but quote that number with
its context: it is almost entirely the 50+ bucket's 97.7%. Reduction scales
monotonically with conversation depth, and the 50+ figure is not a small-sample
artifact — it covers 10,956 requests across 37 conversations.

## How the savings happen

The Curator runs asynchronously after each turn (no added request latency) and applies
deterministic strategies — each one a named method in
[curator.rb](../lib/legion/llm/context/curator.rb):

- `strip_thinking` — drops stale reasoning blocks from prior turns
- `distill_tool_result` — summarizes large tool outputs
- `fold_resolved_exchanges` — collapses completed tool-call/result pairs
- `evict_superseded` — drops an old file-read when a newer read replaces it
- `dedup_similar` — Jaccard-similarity dedup of near-identical content
- `drop_and_archive` — overflow goes to the knowledge store, not the trash

In the 50+ bucket, loaded history of 300.2M tokens was curated down to 106.6M per
request on average, with a further 75.8M archived to the knowledge store rather than
resent. The ledger records curation and archival as separate stages that partially
overlap on the same content, so their per-stage "saved" counters are not additive;
the end-to-end truth is the naive-vs-actual row above, which is stage-independent.

## Caveats and known gaps, stated plainly

- **Single deployment, single author's workload.** Your mix of conversation lengths
  determines your savings; the -0.1% single-turn column is as real as the 97.7% one.
- **The baseline is modeled, not A/B tested.** See the baseline definition above.
- **Provider prompt caching was off in this window** (cached and cache-creation token
  columns were zero). These savings come from payload reduction only, so they stack
  with provider-side caching rather than replacing it.
- **Tool definitions are not yet curated.** They are static, resent every turn, and
  material at scale — a known optimization gap, not a solved problem.

## Reproduce

Every number above is a `SELECT` over lex-llm-ledger tables — the same ledger any
LegionIO deployment gets by installing the extension. The ledger exists for
finance/audit; these metrics are a side effect of never throwing usage data away.
