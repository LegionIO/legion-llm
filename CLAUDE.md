# legion-llm

**Repository Level 3 Documentation**
- **Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## Purpose

Core LegionIO gem providing LLM capabilities to all extensions. Wraps ruby_llm to provide a consistent interface for chat, embeddings, tool use, and agents across multiple providers (Bedrock, Anthropic, OpenAI, Gemini, Ollama). Includes a dynamic weighted routing engine that dispatches requests across local, fleet, and cloud tiers based on caller intent, priority rules, time schedules, cost multipliers, and real-time provider health.

**GitHub**: https://github.com/LegionIO/legion-llm
**License**: Apache-2.0

## Architecture

### Startup Sequence

```
Legion::LLM.start
  ├── 1. Read settings from Legion::Settings[:llm]
  ├── 2. For each enabled provider:
  │     ├── Resolve credentials from Vault (if vault_path set)
  │     └── Configure RubyLLM provider
  └── 3. Auto-detect default model from first enabled provider
```

### Module Structure

```
Legion::LLM (lib/legion/llm.rb)
├── Settings         # Default config, provider settings, routing defaults
├── Providers        # Provider configuration and Vault credential resolution
├── Router           # Dynamic weighted routing engine
│   ├── Resolution   # Value object: tier, provider, model, rule name, metadata
│   ├── Rule         # Routing rule: intent matching, schedule windows, constraints
│   └── HealthTracker # Circuit breaker, latency rolling window, pluggable signal handlers
└── Helpers::LLM     # Extension helper mixin (llm_chat, llm_embed, llm_session)
```

### Routing Architecture

Three-tier dispatch model. Local-first avoids unnecessary network hops; fleet offloads to shared hardware via Transport; cloud is the fallback for frontier models.

```
┌─────────────────────────────────────────────────────────┐
│              Legion::LLM Router (per-node)               │
│                                                          │
│  Tier 1: LOCAL  → Ollama on this machine (direct HTTP)   │
│          Zero network overhead, no Transport              │
│                                                          │
│  Tier 2: FLEET  → Ollama on Mac Studios / GPU servers    │
│          Via Legion::Transport (AMQP) when local can't   │
│          serve the model (Phase 2, not yet built)        │
│                                                          │
│  Tier 3: CLOUD  → Bedrock / Anthropic / OpenAI / Gemini │
│          Existing provider API calls                     │
└─────────────────────────────────────────────────────────┘
```

### Routing Resolution Flow

```
1. Caller passes intent: { privacy: :strict, capability: :basic }
2. Router merges with default_intent (fills missing dimensions)
3. Load rules from settings, filter by:
   a. Intent match (all `when` conditions must match)
   b. Schedule window (valid_from/valid_until, hours, days)
   c. Constraints (e.g., never_cloud strips cloud-tier rules)
   d. Tier availability (is Ollama running? is Transport loaded?)
4. Score remaining candidates:
   effective_priority = rule.priority
                      + health_tracker.adjustment(provider)
                      + (1.0 - cost_multiplier) * 10
5. Return Resolution for highest-scoring candidate
```

### Integration with LegionIO

- **Service**: `setup_llm` called between data and supervision in startup sequence
- **Extensions**: `llm_required?` method on extension module, checked at load time
- **Helpers**: `Legion::Extensions::Helpers::LLM` auto-loaded when gem is present
- **Readiness**: Registers as `:llm` in `Legion::Readiness`
- **Shutdown**: `Legion::LLM.shutdown` called during service shutdown

## Dependencies

| Gem | Purpose |
|-----|---------|
| `ruby_llm` (>= 1.0) | Multi-provider LLM client |
| `legion-logging` | Logging |
| `legion-settings` | Configuration |

## Key Interfaces

```ruby
# Core
Legion::LLM.start                    # Configure providers, set defaults
Legion::LLM.shutdown                 # Cleanup
Legion::LLM.started?                 # -> Boolean
Legion::LLM.settings                 # -> Hash

# Chat (with optional routing)
Legion::LLM.chat(model:, provider:)                         # Direct (no routing)
Legion::LLM.chat(intent: { privacy: :strict })              # Intent-based routing
Legion::LLM.chat(tier: :cloud, model: 'claude-sonnet-4-6')  # Explicit tier override
Legion::LLM.embed(text, model:)                             # Embeddings (no routing)
Legion::LLM.agent(AgentClass)                               # Agent instance

# Router
Legion::LLM::Router.resolve(intent:, tier:, model:, provider:)  # -> Resolution or nil
Legion::LLM::Router.health_tracker                               # -> HealthTracker
Legion::LLM::Router.routing_enabled?                             # -> Boolean
Legion::LLM::Router.reset!                                       # Clear cached state

# HealthTracker
tracker = Legion::LLM::Router.health_tracker
tracker.report(provider: :anthropic, signal: :error, value: 1)   # Feed signal
tracker.report(provider: :ollama, signal: :latency, value: 1200) # Feed latency
tracker.adjustment(:anthropic)                                    # -> Integer (priority offset)
tracker.circuit_state(:anthropic)                                 # -> :closed/:open/:half_open
tracker.register_handler(:gpu_utilization) { |data| ... }         # Extend with new signals
```

## Settings

Settings read from `Legion::Settings[:llm]`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | Boolean | `true` | Enable LLM support |
| `connected` | Boolean | `false` | Set to true after successful start |
| `default_model` | String | `nil` | Default model ID (auto-detected if nil) |
| `default_provider` | Symbol | `nil` | Default provider (auto-detected if nil) |
| `providers` | Hash | See below | Per-provider configuration |
| `routing` | Hash | See below | Dynamic routing engine configuration |

### Provider Settings

Each provider has: `enabled`, `api_key`, `vault_path`, plus provider-specific keys.

Vault credential resolution: When `vault_path` is set and Legion::Crypt::Vault is connected, credentials are fetched from Vault at startup. Keys map to provider-specific fields automatically.

Bedrock supports two auth modes:
- **SigV4** (default): `api_key` + `secret_key` (+ optional `session_token`)
- **Bearer token**: `bearer_token` for AWS Identity Center/SSO. When set, `bedrock_bearer_auth.rb` is required lazily to monkey-patch RubyLLM's Bedrock provider.

### Auto-Detection Priority

When no defaults are configured, the first enabled provider is used:

1. Bedrock -> `us.anthropic.claude-sonnet-4-6-v1`
2. Anthropic -> `claude-sonnet-4-6`
3. OpenAI -> `gpt-4o`
4. Gemini -> `gemini-2.0-flash`
5. Ollama -> `llama3`

### Routing Settings

Nested under `Legion::Settings[:llm][:routing]`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | Boolean | `false` | Enable routing (opt-in) |
| `default_intent` | Hash | `{ privacy: 'normal', capability: 'moderate', cost: 'normal' }` | Defaults merged into every intent |
| `tiers.local` | Hash | `{ provider: 'ollama' }` | Local tier config |
| `tiers.fleet` | Hash | `{ queue: 'llm.inference', timeout_seconds: 30 }` | Fleet tier config |
| `tiers.cloud` | Hash | `{ providers: ['bedrock', 'anthropic'] }` | Cloud tier config |
| `health.window_seconds` | Integer | `300` | Rolling window for latency tracking |
| `health.circuit_breaker.failure_threshold` | Integer | `3` | Consecutive failures before circuit opens |
| `health.circuit_breaker.cooldown_seconds` | Integer | `60` | Seconds before circuit transitions to half_open |
| `health.latency_penalty_threshold_ms` | Integer | `5000` | Latency above this triggers priority penalty |
| `health.budget.daily_limit_usd` | Float | `nil` | Daily cloud spend limit (future) |
| `health.budget.monthly_limit_usd` | Float | `nil` | Monthly cloud spend limit (future) |
| `rules` | Array | `[]` | Routing rules (see below) |

### Routing Rules

Each rule is a hash with:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | String | Yes | Unique rule identifier |
| `when` | Hash | Yes | Intent conditions to match (`privacy`, `capability`, `cost`) |
| `then` | Hash | No | Target: `{ tier:, provider:, model: }` |
| `priority` | Integer | No (default 0) | Higher wins when multiple rules match |
| `constraint` | String | No | Hard constraint (e.g., `never_cloud`) |
| `fallback` | String | No | Fallback tier if primary is unavailable |
| `cost_multiplier` | Float | No (default 1.0) | Lower = cheaper = routing bonus |
| `schedule` | Hash | No | Time-based activation window |
| `note` | String | No | Human-readable note |

### Intent Dimensions

| Dimension | Values | Default | Effect |
|-----------|--------|---------|--------|
| `privacy` | `:strict`, `:normal` | `:normal` | `:strict` -> never cloud (via `never_cloud` constraint rules) |
| `capability` | `:basic`, `:moderate`, `:reasoning` | `:moderate` | Higher prefers larger/cloud models |
| `cost` | `:minimize`, `:normal` | `:normal` | `:minimize` prefers local/fleet |

### Schedule Windows

Rules can include a `schedule` hash for time-based activation:

| Field | Format | Example |
|-------|--------|---------|
| `valid_from` | ISO 8601 | `"2026-03-15T00:00:00"` |
| `valid_until` | ISO 8601 | `"2026-03-29T23:59:59"` |
| `hours` | Array of "HH:MM-HH:MM" | `["00:00-06:00", "18:00-23:59"]` |
| `days` | Array of day names | `["monday", "tuesday"]` |
| `timezone` | IANA timezone | `"America/Chicago"` (stored, not yet used for conversion) |

All fields optional. Omit any to mean "always active."

### HealthTracker

In-memory signal consumer with pluggable handlers. Adjusts effective priorities at runtime.

**Built-in signals:** `:error` (circuit breaker), `:success` (circuit recovery), `:latency` (rolling window penalty)

**Circuit breaker states:**
- `:closed` (normal, adjustment = 0)
- `:open` (after `failure_threshold` consecutive errors, adjustment = -50)
- `:half_open` (after `cooldown_seconds`, tries one request, adjustment = -25)

**Latency penalty:** `-10` per multiple above `LATENCY_THRESHOLD_MS` (5000ms), capped at `-50`

**Extensible:** Call `register_handler(:signal_name) { |data| ... }` to add new signal types. Signal providers (like lex-metering) call `report()` with `defined?(Legion::LLM::Router)` guard.

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/llm.rb` | Entry point: start, shutdown, chat (with routing), embed, agent |
| `lib/legion/llm/settings.rb` | Default settings including routing_defaults, auto-merge into Legion::Settings |
| `lib/legion/llm/providers.rb` | Provider config, Vault resolution, RubyLLM configuration |
| `lib/legion/llm/bedrock_bearer_auth.rb` | Monkey-patch for Bedrock Bearer Token auth — required lazily |
| `lib/legion/llm/router.rb` | Router module: resolve, health_tracker, select_candidates pipeline |
| `lib/legion/llm/router/resolution.rb` | Value object: tier, provider, model, rule, metadata, tier query methods |
| `lib/legion/llm/router/rule.rb` | Rule class: from_hash, matches_intent?, within_schedule?, to_resolution |
| `lib/legion/llm/router/health_tracker.rb` | HealthTracker: circuit breaker, latency window, pluggable signal handlers |
| `lib/legion/llm/version.rb` | Version constant (0.2.0) |
| `lib/legion/llm/helpers/llm.rb` | Extension helper mixin: llm_chat, llm_embed, llm_session |
| `spec/legion/llm_spec.rb` | Tests: settings, lifecycle, providers, auto-config |
| `spec/legion/llm/integration_spec.rb` | Tests: routing integration with chat() |
| `spec/legion/llm/router_spec.rb` | Tests: Router.resolve, priority selection, constraints, health |
| `spec/legion/llm/router/resolution_spec.rb` | Tests: Resolution value object |
| `spec/legion/llm/router/rule_spec.rb` | Tests: Rule intent matching, from_hash, to_resolution |
| `spec/legion/llm/router/rule_schedule_spec.rb` | Tests: Rule schedule evaluation |
| `spec/legion/llm/router/health_tracker_spec.rb` | Tests: circuit breaker, latency, signal handlers |
| `spec/legion/llm/router/settings_spec.rb` | Tests: routing defaults in settings |
| `spec/spec_helper.rb` | Stubbed Legion::Logging and Legion::Settings for testing |

## Extension Integration

Extensions declare LLM dependency via `llm_required?`:

```ruby
module Legion::Extensions::MyLex
  def self.llm_required?
    true
  end
end
```

Helper methods available in runners when gem is loaded:

```ruby
# Direct (no routing)
llm_chat(message, model:, provider:, tools:, instructions:)
llm_embed(text, model:)
llm_session(model:, provider:)

# With routing
llm_chat(message, intent: { privacy: :strict, capability: :basic })
llm_chat(message, tier: :cloud, model: 'claude-sonnet-4-6')
llm_session(intent: { capability: :reasoning })
```

## Vault Integration

Provider credentials are resolved from Vault when:
1. `vault_path` is set on the provider config
2. `Legion::Crypt` is defined and Vault is connected (`Legion::Settings[:crypt][:vault][:connected]`)

Key mapping:
- **Bedrock**: `access_key`/`aws_access_key_id` -> `api_key`, `secret_key`/`aws_secret_access_key` -> `secret_key`
- **Anthropic/OpenAI/Gemini**: `api_key`/`token` -> `api_key`

Direct config values take precedence over Vault-resolved values.

## Testing

Tests run without the full LegionIO stack. `spec/spec_helper.rb` stubs `Legion::Logging` and `Legion::Settings` with in-memory implementations. Each test resets settings to defaults via `before(:each)`.

```bash
bundle exec rspec    # 153 examples, 0 failures
bundle exec rubocop  # 21 files, 0 offenses
```

## Design Documents

- `docs/plans/2026-03-14-llm-dynamic-routing-design.md` — Full design (approved)
- `docs/plans/2026-03-14-llm-dynamic-routing-implementation.md` — Implementation plan

## Future (Not Yet Built)

- **Fleet tier (Phase 2)**: `lex-llm-fleet` extension — inference workers on Mac Studios / NVIDIA servers, dispatched via Legion::Transport AMQP queues
- **Advanced signals (Phase 3)**: Budget tracking, lex-metering integration, GPU utilization monitoring
- **Timezone support**: `within_schedule?` stores timezone but does not convert yet (needs TZInfo)

---

**Maintained By**: Matthew Iverson (@Esity)
