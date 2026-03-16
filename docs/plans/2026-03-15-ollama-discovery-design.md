# Ollama Model Discovery & System Memory Awareness

**Date**: 2026-03-15
**Author**: Matthew Iverson (@Esity)
**Status**: Approved

## Problem

Legion::LLM's router can target Ollama models via routing rules, but has no awareness of:
1. Which models are actually pulled in the local Ollama instance
2. How much system memory is available to run them

This leads to rules targeting models that aren't present (silent failures falling through to cloud) and no protection against selecting models too large for available RAM.

## Solution

Add two discovery modules under `Legion::LLM::Discovery` that provide lazy TTL-cached system introspection. The router uses this data to filter candidates before scoring.

## Architecture

### Module Structure

```
Legion::LLM::Discovery
├── Ollama   # Queries Ollama /api/tags for pulled models
└── System   # Queries OS for memory stats (macOS + Linux)
```

### Discovery::Ollama

Queries `GET <base_url>/api/tags` via Faraday (transitive dep from ruby_llm).

```ruby
Discovery::Ollama
  .models            # -> Array<Hash> (raw model list)
  .model_names       # -> Array<String> (names for quick lookup)
  .model_available?(name) # -> Boolean
  .model_size(name)       # -> Integer (bytes) or nil
  .refresh!          # Force re-fetch
  .reset!            # Clear cache (testing)
  .stale?            # -> Boolean (TTL expired?)
```

Response format from Ollama `/api/tags`:
```json
{
  "models": [
    {
      "name": "llama3.1:8b",
      "size": 4700000000,
      "digest": "sha256:...",
      "modified_at": "2026-03-15T..."
    }
  ]
}
```

Connection: 2-second timeout, uses `ollama[:base_url]` from settings (default `http://localhost:11434`).

### Discovery::System

Queries OS-level memory information. Platform-aware:

- **macOS**: `sysctl -n hw.memsize` (total), `vm_stat` (free + inactive pages, excludes disk cache)
- **Linux**: `/proc/meminfo` (MemTotal, MemFree + Inactive)

```ruby
Discovery::System
  .total_memory_mb     # -> Integer
  .available_memory_mb # -> Integer (free + inactive, no disk cache)
  .memory_pressure?    # -> Boolean (available < memory_floor_mb)
  .platform            # -> :macos | :linux | :unknown
  .refresh!
  .reset!
  .stale?
```

### Router Integration

The existing `select_candidates` pipeline gains one new filter step:

```
Current pipeline:
1. Collect constraints from constraint rules
2. Filter by intent match
3. Filter by schedule
4. Reject rules excluded by constraints
5. Filter by tier availability

New pipeline:
1. Collect constraints from constraint rules
2. Filter by intent match
3. Filter by schedule
4. Reject rules excluded by constraints
4.5  Reject Ollama rules where model is not pulled or doesn't fit in memory  <-- NEW
5. Filter by tier availability
```

Step 4.5 logic:
- Only applies to rules where target tier is `:local` and provider is `:ollama`
- Skip if `Discovery::Ollama.model_available?(model)` returns false
- Skip if model size > (`Discovery::System.available_memory_mb - memory_floor_mb`) * 1MB
- All non-Ollama rules pass through unchanged
- If discovery is disabled (`enabled: false`), skip all checks (permissive)

### Startup Integration

In `Legion::LLM.start`, after `configure_providers` and before `set_defaults`:

```ruby
if settings.dig(:providers, :ollama, :enabled)
  Discovery::Ollama.refresh!
  Discovery::System.refresh!
  Legion::Logging.info "Ollama: #{Discovery::Ollama.model_names.size} models available " \
                       "(#{Discovery::Ollama.model_names.join(', ')})"
  Legion::Logging.info "System: #{Discovery::System.total_memory_mb} MB total, " \
                       "#{Discovery::System.available_memory_mb} MB available"
end
```

### Settings

New settings nested under `Legion::Settings[:llm][:discovery]`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | Boolean | `true` | Master switch for discovery checks |
| `refresh_seconds` | Integer | `60` | TTL for both discovery caches |
| `memory_floor_mb` | Integer | `2048` | Minimum free MB to reserve for OS |

Added to `Legion::LLM::Settings.default` and merged via `routing_defaults`.

### Error Handling

| Scenario | Behavior |
|----------|----------|
| Ollama not running | `models` returns `[]`, all Ollama rules skipped, cloud tier takes over |
| `vm_stat` fails | `available_memory_mb` returns `nil`, memory checks bypassed (permissive) |
| `/api/tags` timeout (2s) | Returns stale cache if available, empty array on first call |
| Discovery disabled | All checks bypassed, rules pass through as before |
| Unknown platform | `available_memory_mb` returns `nil`, memory checks bypassed |

### File Layout

```
lib/legion/llm/discovery/ollama.rb
lib/legion/llm/discovery/system.rb
spec/legion/llm/discovery/ollama_spec.rb
spec/legion/llm/discovery/system_spec.rb
```

### Dependencies

No new gem dependencies. Uses:
- `Faraday` (transitive via ruby_llm) for Ollama HTTP
- Shell commands (`sysctl`, `vm_stat`) for macOS memory
- File reads (`/proc/meminfo`) for Linux memory

## Out of Scope

- Auto-pulling models (explicit operator action only)
- GPU utilization monitoring (future HealthTracker signal)
- Fleet tier discovery (Phase 2)
- Disk space checks for model storage
