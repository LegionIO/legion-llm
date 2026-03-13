# legion-llm

**Repository Level 3 Documentation**
- **Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## Purpose

Core LegionIO gem providing LLM capabilities to all extensions. Wraps ruby_llm to provide a consistent interface for chat, embeddings, tool use, and agents across multiple providers (Bedrock, Anthropic, OpenAI, Gemini, Ollama).

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
├── Settings         # Default config, provider settings
├── Providers        # Provider configuration and Vault credential resolution
└── Helpers::LLM     # Extension helper mixin (llm_chat, llm_embed, llm_session)
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
Legion::LLM.start                    # Configure providers, set defaults
Legion::LLM.shutdown                 # Cleanup
Legion::LLM.chat(model:, provider:)  # -> RubyLLM::Chat
Legion::LLM.embed(text, model:)      # -> RubyLLM::Embedding
Legion::LLM.agent(AgentClass)        # -> RubyLLM::Agent instance
Legion::LLM.started?                 # -> Boolean
Legion::LLM.settings                 # -> Hash
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

### Provider Settings

Each provider has: `enabled`, `api_key`, `vault_path`, plus provider-specific keys.

Vault credential resolution: When `vault_path` is set and Legion::Crypt::Vault is connected, credentials are fetched from Vault at startup. Keys map to provider-specific fields automatically.

### Auto-Detection Priority

When no defaults are configured, the first enabled provider is used:

1. Bedrock -> `us.anthropic.claude-sonnet-4-6-v1`
2. Anthropic -> `claude-sonnet-4-6`
3. OpenAI -> `gpt-4o`
4. Gemini -> `gemini-2.0-flash`
5. Ollama -> `llama3`

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/llm.rb` | Entry point: start, shutdown, chat, embed, agent |
| `lib/legion/llm/settings.rb` | Default settings, auto-merge into Legion::Settings |
| `lib/legion/llm/providers.rb` | Provider config, Vault resolution, RubyLLM configuration |
| `lib/legion/llm/version.rb` | Version constant |
| `lib/legion/llm/helpers/llm.rb` | Extension helper mixin |
| `spec/legion/llm_spec.rb` | Tests for settings, lifecycle, providers, auto-config |
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
llm_chat(message, model:, provider:, tools:, instructions:)  # One-shot chat
llm_embed(text, model:)                                       # Embeddings
llm_session(model:, provider:)                                # Multi-turn session
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
bundle exec rspec
```

---

**Maintained By**: Matthew Iverson (@Esity)
