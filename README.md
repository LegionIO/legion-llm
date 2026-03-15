# Legion LLM

LLM integration for the [LegionIO](https://github.com/LegionIO/LegionIO) framework. Wraps [ruby_llm](https://github.com/crmne/ruby_llm) to provide chat, embeddings, tool use, and agent capabilities to any Legion extension.

## Installation

```ruby
gem 'legion-llm'
```

Or add to your Gemfile and `bundle install`.

## Configuration

Add to your LegionIO settings directory:

```json
{
  "llm": {
    "default_model": "us.anthropic.claude-sonnet-4-6-v1",
    "default_provider": "bedrock",
    "providers": {
      "bedrock": {
        "enabled": true,
        "region": "us-east-2",
        "vault_path": "legion/bedrock"
      },
      "anthropic": {
        "enabled": false,
        "vault_path": "legion/anthropic"
      },
      "openai": {
        "enabled": false
      },
      "ollama": {
        "enabled": false,
        "base_url": "http://localhost:11434"
      }
    }
  }
}
```

Credentials are resolved from Vault automatically when `vault_path` is set and Legion::Crypt is connected.

### Provider Configuration

Each provider supports these common fields:

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | Boolean | Enable this provider (default: `false`) |
| `api_key` | String | API key (resolved from Vault if `vault_path` set) |
| `vault_path` | String | Vault secret path for credential resolution |

Provider-specific fields:

| Provider | Additional Fields |
|----------|------------------|
| **Bedrock** | `secret_key`, `session_token`, `region` (default: `us-east-2`), `bearer_token` (alternative to SigV4 — for AWS Identity Center/SSO) |
| **Ollama** | `base_url` (default: `http://localhost:11434`) |

### Vault Credential Resolution

When `vault_path` is set and `Legion::Crypt::Vault` is connected, credentials are fetched from Vault at startup. The secret keys map to provider fields automatically:

| Provider | Vault Key | Maps To |
|----------|-----------|---------|
| Bedrock | `access_key` / `aws_access_key_id` | `api_key` |
| Bedrock | `secret_key` / `aws_secret_access_key` | `secret_key` |
| Bedrock | `session_token` / `aws_session_token` | `session_token` |
| Bedrock | `bearer_token` / `aws_bearer_token` | `bearer_token` (Identity Center/SSO) |
| Anthropic / OpenAI / Gemini | `api_key` / `token` | `api_key` |

Direct configuration (setting `api_key` in settings) takes precedence over Vault-resolved values.

### Auto-Detection

If no `default_model` or `default_provider` is set, legion-llm auto-detects from the first enabled provider in priority order:

| Priority | Provider | Default Model |
|----------|----------|---------------|
| 1 | Bedrock | `us.anthropic.claude-sonnet-4-6-v1` |
| 2 | Anthropic | `claude-sonnet-4-6` |
| 3 | OpenAI | `gpt-4o` |
| 4 | Gemini | `gemini-2.0-flash` |
| 5 | Ollama | `llama3` |

## Core API

### Lifecycle

```ruby
Legion::LLM.start       # Configure providers from settings, resolve Vault credentials, set defaults
Legion::LLM.shutdown     # Mark disconnected, clean up
Legion::LLM.started?     # -> Boolean
Legion::LLM.settings     # -> Hash (current LLM settings)
```

### Chat

Returns a `RubyLLM::Chat` instance for multi-turn conversation:

```ruby
# Use configured defaults
chat = Legion::LLM.chat
response = chat.ask("What is the capital of France?")
puts response.content

# Override model/provider per call
chat = Legion::LLM.chat(model: 'gpt-4o', provider: :openai)

# Multi-turn conversation
chat = Legion::LLM.chat
chat.ask("Remember: my name is Matt")
chat.ask("What's my name?")  # -> "Matt"
```

### Embeddings

```ruby
embedding = Legion::LLM.embed("some text to embed")
embedding.vectors  # -> Array of floats

# Specific model
embedding = Legion::LLM.embed("text", model: "text-embedding-3-small")
```

### Tool Use

Define tools as Ruby classes and attach them to a chat session. RubyLLM handles the tool-use loop automatically — when the model calls a tool, ruby_llm executes it and feeds the result back:

```ruby
class WeatherLookup < RubyLLM::Tool
  description "Look up current weather for a location"

  param :location, desc: "City name or zip code"
  param :units, desc: "celsius or fahrenheit", required: false

  def execute(location:, units: "fahrenheit")
    # Your weather API call here
    { temperature: 72, conditions: "sunny", location: location }
  end
end

chat = Legion::LLM.chat
chat.with_tools(WeatherLookup)
response = chat.ask("What's the weather in Minneapolis?")
# Model calls WeatherLookup, gets result, responds with natural language
```

### Structured Output

Use `RubyLLM::Schema` to get typed, validated responses:

```ruby
class SentimentResult < RubyLLM::Schema
  string :sentiment, enum: %w[positive negative neutral]
  number :confidence
  string :reasoning
end

chat = Legion::LLM.chat
result = chat.with_output_schema(SentimentResult).ask("Analyze: 'I love this product!'")
result.sentiment    # -> "positive"
result.confidence   # -> 0.95
result.reasoning    # -> "Strong positive language..."
```

### Agents

Define reusable agents as `RubyLLM::Agent` subclasses with declarative configuration:

```ruby
class CodeReviewer < RubyLLM::Agent
  model "us.anthropic.claude-sonnet-4-6-v1", provider: :bedrock
  instructions "You review code for bugs, security issues, and style"
  tools CodeAnalyzer, SecurityScanner
  temperature 0.1

  schema do
    string :verdict, enum: %w[approve request_changes]
    array :issues do
      string
    end
  end
end

reviewer = Legion::LLM.agent(CodeReviewer)
result = reviewer.ask(diff_content)
result.verdict  # -> "approve" or "request_changes"
result.issues   # -> ["Line 42: potential SQL injection", ...]
```

## Usage in Extensions

Any LEX extension can use LLM capabilities. The gem provides helper methods that are auto-loaded when legion-llm is present.

### Basic Extension Usage

```ruby
module Legion::Extensions::MyLex::Runners
  module Analyzer
    def analyze(text:, **_opts)
      chat = Legion::LLM.chat
      response = chat.ask("Analyze this: #{text}")
      { analysis: response.content }
    end
  end
end
```

### Declaring LLM as Required

Extensions that cannot function without LLM should declare the dependency. Legion will skip loading the extension if LLM is not available:

```ruby
module Legion::Extensions::MyLex
  def self.llm_required?
    true
  end
end
```

### Helper Methods

Include the LLM helper for convenience methods in any runner:

```ruby
# One-shot chat (returns RubyLLM::Response)
result = llm_chat("Summarize this text", instructions: "Be concise")

# Chat with tools
result = llm_chat("Check the weather", tools: [WeatherLookup])

# With prompt compression (reduces input tokens for cost/speed)
result = llm_chat("Summarize the data", instructions: "Be concise", compress: 2)

# Embeddings
embedding = llm_embed("some text to embed")

# Multi-turn session (returns RubyLLM::Chat for continued conversation)
session = llm_session
session.with_instructions("You are a code reviewer")
session.with_tools(CodeAnalyzer, SecurityScanner)
response = session.ask("Review this PR: #{diff}")
```

### Routing

legion-llm includes a dynamic weighted routing engine that dispatches requests across local, fleet, and cloud tiers based on caller intent, priority rules, time schedules, cost multipliers, and real-time provider health. Routing is **disabled by default** — opt in via settings.

#### Three Tiers

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

| Tier | Target | Use Case |
|------|--------|----------|
| `local` | Ollama on localhost | Privacy-sensitive, offline, or low-latency workloads |
| `fleet` | Shared hardware via Legion::Transport | Larger models on dedicated GPU servers (Phase 2) |
| `cloud` | API providers (Bedrock, Anthropic, OpenAI, Gemini) | Frontier models, full-capability inference |

#### Intent-Based Dispatch

Pass an `intent:` hash to route based on privacy, capability, or cost requirements:

```ruby
# Route to local tier for strict privacy
result = llm_chat("Summarize this PII data", intent: { privacy: :strict })

# Route to cloud for reasoning tasks
result = llm_chat("Solve this proof", intent: { capability: :reasoning })

# Minimize cost — prefers local/fleet over cloud
result = llm_chat("Translate this", intent: { cost: :minimize })

# Explicit tier override (bypasses rules)
result = llm_chat("Translate this", tier: :cloud, model: "claude-sonnet-4-6")
```

Same parameters work on `Legion::LLM.chat` and `llm_session`:

```ruby
chat = Legion::LLM.chat(intent: { privacy: :strict, capability: :basic })
session = llm_session(tier: :local)
```

#### Intent Dimensions

| Dimension | Values | Default | Effect |
|-----------|--------|---------|--------|
| `privacy` | `:strict`, `:normal` | `:normal` | `:strict` -> never cloud (via constraint rules) |
| `capability` | `:basic`, `:moderate`, `:reasoning` | `:moderate` | Higher prefers larger/cloud models |
| `cost` | `:minimize`, `:normal` | `:normal` | `:minimize` prefers local/fleet |

#### Routing Resolution

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

#### Settings

Add routing configuration under the `llm` key:

```json
{
  "llm": {
    "routing": {
      "enabled": true,
      "default_intent": { "privacy": "normal", "capability": "moderate", "cost": "normal" },
      "tiers": {
        "local": { "provider": "ollama" },
        "fleet": { "queue": "llm.inference", "timeout_seconds": 30 },
        "cloud": { "providers": ["bedrock", "anthropic"] }
      },
      "health": {
        "window_seconds": 300,
        "circuit_breaker": { "failure_threshold": 3, "cooldown_seconds": 60 },
        "latency_penalty_threshold_ms": 5000
      },
      "rules": [
        {
          "name": "privacy_local",
          "when": { "privacy": "strict" },
          "then": { "tier": "local", "provider": "ollama", "model": "llama3" },
          "priority": 100,
          "constraint": "never_cloud"
        },
        {
          "name": "reasoning_cloud",
          "when": { "capability": "reasoning" },
          "then": { "tier": "cloud", "provider": "bedrock", "model": "us.anthropic.claude-sonnet-4-6-v1" },
          "priority": 50,
          "cost_multiplier": 1.0
        },
        {
          "name": "anthropic_promo",
          "when": { "cost": "normal" },
          "then": { "tier": "cloud", "provider": "anthropic", "model": "claude-sonnet-4-6" },
          "priority": 60,
          "cost_multiplier": 0.5,
          "schedule": {
            "valid_from": "2026-03-15T00:00:00",
            "valid_until": "2026-03-29T23:59:59",
            "hours": ["00:00-06:00", "18:00-23:59"]
          },
          "note": "Double token promotion — off-peak hours only"
        }
      ]
    }
  }
}
```

#### Routing Rules

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

#### Health Tracking

The `HealthTracker` adjusts effective priorities at runtime based on provider health signals:

- **Circuit breaker**: After consecutive failures, a provider's circuit opens (penalty: -50) then transitions to half_open (penalty: -25) after a cooldown period
- **Latency penalty**: Rolling window tracks average latency; providers above threshold receive priority penalties
- **Pluggable signals**: Any LEX can feed custom signals (e.g., GPU utilization, budget tracking) via `register_handler`

```ruby
# Report signals (typically called by LEX extensions)
tracker = Legion::LLM::Router.health_tracker
tracker.report(provider: :anthropic, signal: :error, value: 1)
tracker.report(provider: :ollama, signal: :latency, value: 1200)

# Check state
tracker.circuit_state(:anthropic)  # -> :closed, :open, or :half_open
tracker.adjustment(:anthropic)     # -> Integer (priority offset)

# Add custom signal handler
tracker.register_handler(:gpu_utilization) { |data| ... }
```

When routing is disabled (the default), `chat`, `llm_chat`, and `llm_session` behave exactly as before — no behavior change until you opt in.

### Prompt Compression

`Legion::LLM::Compressor` strips low-signal words from prompts before sending to the API, reducing input token count and cost. Compression is deterministic (same input always produces the same output), preserving prompt caching compatibility.

#### Levels

| Level | Name | What It Removes |
|-------|------|-----------------|
| 0 | None | Nothing |
| 1 | Light | Articles (a, an, the), filler adverbs (just, very, really, basically, ...) |
| 2 | Moderate | + sentence connectives (however, moreover, furthermore, ...) |
| 3 | Aggressive | + low-signal words (also, then, please, note, that, ...) + whitespace normalization |

Code blocks (fenced and inline) are never modified. Negation words are never removed.

#### Usage

```ruby
# Direct API
text = Legion::LLM::Compressor.compress("The very important system prompt", level: 2)

# Via llm_chat helper (compresses both message and instructions)
result = llm_chat("Analyze the data", instructions: "Be very concise", compress: 2)
```

#### Router Integration

Routing rules can specify `compress_level` in their target to auto-compress for cost-sensitive tiers:

```json
{
  "name": "cloud_compressed",
  "priority": 50,
  "when": { "capability": "chat" },
  "then": { "tier": "cloud", "provider": "bedrock", "model": "claude-sonnet-4-6", "compress_level": 2 }
}
```

### Building an LLM-Powered LEX

A complete example of a LEX extension that uses LLM for intelligent processing:

```ruby
# lib/legion/extensions/smart_alerts/runners/evaluate.rb
module Legion::Extensions::SmartAlerts::Runners
  module Evaluate
    def evaluate(alert_data:, **_opts)
      session = llm_session(model: 'us.anthropic.claude-sonnet-4-6-v1')
      session.with_instructions(<<~PROMPT)
        You are an alert triage system. Given alert data, determine:
        1. Severity (critical, warning, info)
        2. Whether it requires immediate human attention
        3. Suggested remediation steps
      PROMPT

      result = session.ask("Evaluate this alert: #{alert_data.to_json}")

      {
        evaluation: result.content,
        timestamp: Time.now.utc,
        model: 'us.anthropic.claude-sonnet-4-6-v1'
      }
    end
  end
end
```

## Providers

| Provider | Config Key | Credential Source | Notes |
|----------|-----------|-------------------|-------|
| AWS Bedrock | `bedrock` | Vault (`access_key`, `secret_key`) or direct | Default region: us-east-2 |
| Anthropic | `anthropic` | Vault (`api_key`) or direct | Direct API access |
| OpenAI | `openai` | Vault (`api_key`) or direct | GPT models |
| Google Gemini | `gemini` | Vault (`api_key`) or direct | Gemini models |
| Ollama | `ollama` | Local, no credentials needed | Local inference |

## Integration with LegionIO

legion-llm follows the standard core gem lifecycle:

```
Legion::Service#initialize
  ...
  setup_data           # Legion::Data
  setup_llm            # Legion::LLM  <-- here
  setup_supervision    # Legion::Supervision
  load_extensions      # LEX extensions (can use LLM if available)
```

- **Service**: `setup_llm` called between data and supervision in startup sequence
- **Extensions**: `llm_required?` method on extension module, checked at load time
- **Helpers**: `Legion::Extensions::Helpers::LLM` auto-loaded when gem is present
- **Readiness**: Registers as `:llm` in `Legion::Readiness`
- **Shutdown**: `Legion::LLM.shutdown` called during service shutdown (reverse order)

## Development

```bash
git clone https://github.com/LegionIO/legion-llm.git
cd legion-llm
bundle install
bundle exec rspec
```

### Running Tests

Tests use stubbed `Legion::Logging` and `Legion::Settings` modules (no need for the full LegionIO stack):

```bash
bundle exec rspec                              # Run all 153 tests
bundle exec rubocop                            # Lint (0 offenses)
bundle exec rspec spec/legion/llm_spec.rb      # Run specific test file
bundle exec rspec spec/legion/llm/router_spec.rb  # Router tests only
```

## Dependencies

| Gem | Purpose |
|-----|---------|
| `ruby_llm` (>= 1.0) | Multi-provider LLM client |
| `legion-logging` | Logging |
| `legion-settings` | Configuration |

## License

Apache-2.0
