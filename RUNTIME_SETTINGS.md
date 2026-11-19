# Runtime settings

All paths below are under `Legion::Settings[:llm]`. Defaults live in
[`lib/legion/llm/settings.rb`](lib/legion/llm/settings.rb) and its existing
`settings/` modules. Consumers inherit missing/nil keys from that owner. Explicit
`false` and valid zero values are preserved. Newly configurable bounds reject
invalid scalar values with `ArgumentError` identifying the key. Nested string keys
are accepted by the runtime resolver.

| Settings group | Policy and units |
| --- | --- |
| `daemon` | Health cache TTL and health/open/read/inference timeouts, in seconds. Per-call timeout wins. The daemon URL retains its existing cached-until-reset behavior. |
| `context_curation` | Context target in tokens, recent-turn counts, exchange window in messages, result/preview/distillation/scan budgets in characters, command tail in lines. Existing archival policy is unchanged. |
| `compressor` | Summary threshold in estimated tokens, input clipping multiplier in characters per token, summary budget ratio, dedup window in messages and minimum content in characters. These retain their existing compression-input meaning; generation uses the normal inference output budget. |
| `embedding` | Chunk target in estimated tokens, preferred text-boundary ratio. Selected-lane context evidence still bounds each chunk. Embedding cache TTL is in seconds. |
| `vector_store` | Unique file IDs per batch, database scan limit in chunks, paragraph grouping target in characters. Oversized single paragraphs retain existing behavior. |
| `conversation`, `metering.token_history_limit`, `shadow.max_history` | In-memory retention counts and metadata search tail in messages. A lower conversation cap is enforced on the next insertion. Zero token/shadow history retains no entries. |
| `prompt_caching` | Existing prompt-cache flags, token threshold and scope. `response_cache` owns generic response TTL, polling interval in seconds, spool byte threshold and spool directory. |
| `knowledge_capture`, `rag_guard` | Existing opt-in capture/blocking flags, captured content limit in characters, confidence and faithfulness thresholds. Missing flags no longer enable a disabled feature. |
| `quality`, `confidence` | Minimum lengths in characters, repetition counts, score bands, penalties and log-probability floor. Per-call quality/band overrides retain precedence. Pattern recognition algorithms are unchanged. |
| `reflection`, `debate` | Extraction thresholds, per-kind entry counts/confidence, cooldown seconds and retained summary lengths in characters. Hook reachability and debate routing are unchanged. |
| `skills.discovery_roots` | Claude skills, Claude plugins and Codex skills roots. Discovery remains opt-in through `skills.auto_discover`; explicit `skills.directories` still works. |
| `files` | Shared storage root, maximum part and total upload sizes in bytes. `LEGION_UPLOAD_MAX_PART_MB` and `LEGION_UPLOAD_MAX_TOTAL_MB` still seed defaults in MiB; explicit settings overlays win. |
| `moderation` | Maximum inputs per request and generation output tokens. |
| `tools.native` | Grep include pattern, grep line cap, glob match cap and default web-search result count. Explicit tool-call result counts retain precedence. |
| `logging`, `compliance.tool_audit_result_max_chars` | Diagnostic previews and tool-result audit clipping in characters; tool-name list cap in names. These do not truncate provider/client tool results. |
| `api` | Native chat worker count, native chat shutdown wait in seconds, tier cache TTL in seconds. |
| `batch`, `scheduling` | Existing batch size/window and scheduling policies. Missing deferred-intent configuration inherits the registered list. |
| `fleet` | Existing JWT identity/algorithm defaults and publisher-confirm timeout in milliseconds. Fleet protocol and cryptographic contract are unchanged. |
| `gaia.partner_context_limit` | Existing partner lookup result count. This does not implement the broader scoped-GAIA migration in #197. |
| `metering.spool` | File path, retained event count and inter-event flush sleep in seconds. |

Most values are read when the operation runs. A routing request keeps its immutable
settings snapshot across global reloads. Native chat pools capture worker count on
first use and retain it until shutdown/restart; they are not resized with jobs in
flight. No data is migrated or deleted when a storage path changes. Relative paths
retain normal process-relative behavior; `~` is expanded for file, spool and
discovery roots.

Registered defaults win where older fallbacks conflicted: knowledge capture, RAG
blocking and skill auto-discovery are disabled; prompt caching is enabled; curation
uses its registered context and tool-result budgets; embedding cache expiry uses
the embedding policy. Explicit operator values still win.

Protocol identifiers, wire enums/default model names, unit conversions, token
estimation math and detection patterns remain in their owning algorithms or
translators. They are not operator budgets or a second model catalog. The unused
embedding prefix constant was removed; prefix policy already comes from settings.
The shared inference worker backlog is tracked separately by #222/#191; the native
HTTP pool settings here do not claim to resolve it.
