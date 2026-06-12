# G26 — Prompt Caching: Never Activated

## Root Causes

### RC1: Provider#cache_enabled? silent-false (lex-llm)

**CONFIRMED by:** spec asserting HashConfig-constructed provider returns true when
`Legion::Settings[:llm][:prompt_caching][:enabled]` is true.

`Provider#cache_enabled?` (provider.rb:226) only checked `config.respond_to?(:llm_cache_enabled)`.
When a provider is instantiated by the adapter with a plain Hash config (which is what every
lex-llm-* adapter does), `HashConfig#respond_to?` returns false because the key was never
in the hash — silently returning `false` without ever consulting the global setting.

**Fix:** Hierarchy: explicit per-provider `llm_cache_enabled` if present → global
`Legion::Settings[:llm][:prompt_caching][:enabled]`. Debug log emitted once per decision.

### RC2: Client translator strips cache_control from system blocks (legion-llm)

**CONFIRMED by:** spec + code reading.

`ClientTranslators::AnthropicMessages#extract_system` flattened all system text blocks to a
joined string, dropping any `cache_control` markers the client sent. The legacy
`Translators::AnthropicRequest#extract_system` preserved them — but the Phase 5 replacement
didn't.

**Fix:** When any system block carries `cache_control`, return an Array of Hashes (with
`cache_control` preserved) instead of a flat string.

### RC3: Anthropic provider translator drops cache_control from ContentBlock (lex-llm-anthropic)

**CONFIRMED by:** code reading of `content_block_to_wire` and `hash_block_to_wire`.

Both methods rendered wire-format hashes but never included `block.cache_control` or
`block[:cache_control]` even when present on the canonical ContentBlock.

**Fix:** Both methods now append `cache_control` to the wire hash when non-nil.

### RC4: Bedrock invoke_model missing system field (lex-llm-bedrock)

**CONFIRMED by:** code reading — `render_invoke_model` never rendered a `system` key.

The Bedrock translator's `invoke_model` target uses the Anthropic Messages wire format
(for Anthropic models with thinking/tools), which supports a `system` array field.
This field was absent, so system-prompt caching was impossible on the invoke_model path.

**Fix:** Added `render_invoke_system` helper that produces `[{type:'text', text:, cache_control:}]`
with passthrough.

### RC5: OpenAI usage.cached_tokens invisible to ledger (lex-llm + lex-llm-openai)

**CONFIRMED by:** spec using real OpenAI usage payload shapes.

OpenAI nests cache info under `usage.prompt_tokens_details.cached_tokens` (Chat API) and
`usage.input_tokens_details.cached_tokens` (Responses API). `Canonical::Usage.from_hash`
only mapped top-level aliases, never digging into nested details objects.

**Fix:** Both `Usage.from_hash` (belt-and-suspenders) and the OpenAI translator's
`parse_usage` now extract nested `cached_tokens` → `cache_read_tokens` and
`reasoning_tokens` → `thinking_tokens`.

## Fixes (file:line, commit SHA)

| Repo | File | Commit |
|------|------|--------|
| lex-llm | `lib/legion/extensions/llm/provider.rb:226` | a9ea6f96 |
| lex-llm | `lib/legion/extensions/llm/canonical/usage.rb:28-40` | a9ea6f96 |
| lex-llm-anthropic | `lib/legion/extensions/llm/anthropic/translator.rb:235-251` | b715103 |
| lex-llm-bedrock | `lib/legion/extensions/llm/bedrock/translator.rb:233-250` | f9af9c2 |
| lex-llm-openai | `lib/legion/extensions/llm/openai/translator.rb:354-375` | d6625da |
| legion-llm | `lib/legion/llm/api/client_translators/anthropic_messages.rb:526-537` | e117c46 |

## Sibling Check

| Translator | cache_control handling | Status |
|------------|----------------------|--------|
| Anthropic (lex-llm-anthropic) | Fixed: content_block_to_wire + hash_block_to_wire | ✅ |
| Bedrock (lex-llm-bedrock) | Fixed: render_invoke_system + passthrough | ✅ |
| OpenAI (lex-llm-openai) | N/A — server-side caching, no wire markers needed; usage extraction fixed | ✅ |
| Ollama (lex-llm-ollama) | N/A — local provider, no caching support | N/A |
| vLLM (lex-llm-vllm) | N/A — local provider, no caching support | N/A |
| MLX (lex-llm-mlx) | N/A — local provider | N/A |
| Vertex (lex-llm-vertex) | N/A — uses Gemini wire format, separate caching mechanism | N/A |
| Azure Foundry | N/A — uses OpenAI-compat format, server-side caching | N/A |

## Suite Counts

| Repo | Examples | Failures | Offenses |
|------|----------|----------|----------|
| lex-llm | 647 | 0 | 0 |
| lex-llm-anthropic | 135 | 0 | 0 |
| lex-llm-bedrock | 194 | 0 | 0 (lib/) |
| lex-llm-openai | 145 | 0 | 0 (lib/) |
| legion-llm | 3064 | 0 | 0 (changed files) |

## Restart List (gems changed)

- `lex-llm` (provider.rb, canonical/usage.rb)
- `lex-llm-anthropic` (translator.rb)
- `lex-llm-bedrock` (translator.rb)
- `lex-llm-openai` (translator.rb)
- `legion-llm` (client_translators/anthropic_messages.rb)

## Expected Live Outcomes (EXPECTED — unconfirmed until human restart)

| Cell | Expected |
|------|----------|
| anthropic (2nd identical large-system-prompt payload) | `cache_read_input_tokens > 0` in response usage |
| bedrock invoke_model (2nd identical payload) | `cache_read_input_tokens > 0` in response usage |
| openai (any request) | `cache_read_tokens` populated in ledger from nested details |
| ledger C4 evidence | All three providers report non-zero `cache_read_tokens` on cache-eligible repeated requests |

## Hypotheses Disproved

- "The PromptCache step isn't running" — FALSE. The step IS included and fires correctly
  (spec green, log lines confirm). The issue is that the lex-llm-anthropic provider's
  OLD render path (`render_payload`) uses `cache_enabled?` to gate its own marker
  injection, and `cache_enabled?` was always false.
- "cache_control markers are being stripped at the executor level" — FALSE. The executor
  passes system blocks through via `ContextWindow` and `native_dispatch_messages` without
  touching cache_control. The strip happens at the translator boundary (RC2, RC3).
