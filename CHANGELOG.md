# Legion LLM Changelog

## [Unreleased]

## [0.3.0] - 2026-03-16

### Added
- Model escalation on retry: automatic fallback to more capable models on hard or quality failures
- `Router.resolve_chain` returns ordered `EscalationChain` of fallback resolutions
- `QualityChecker` module with built-in heuristics (empty, too_short, repetition, json_parse) and pluggable checks
- `EscalationHistory` mixin tracks attempts on response objects (`escalated?`, `escalation_history`, `final_resolution`)
- `chat(escalate: true, message:)` retry loop with configurable `max_escalations:` and `quality_check:`
- HealthTracker `:quality_failure` signal with half-weight failure counting (6 quality failures to trip circuit)
- AMQP transport: `llm.escalation` exchange + `EscalationEvent` message for fleet-wide observability
- Settings: `routing.escalation.enabled`, `max_attempts`, `quality_threshold`
- Helper passthrough: `llm_chat` accepts `escalate:`, `max_escalations:`, `quality_check:`

## [0.2.3]

### Added
- Timezone support for routing schedule windows via TZInfo
- `within_schedule?` converts `now` to the schedule's IANA timezone before evaluating hours and days
- `tzinfo` (>= 2.0) runtime dependency

## [0.2.2]

### Added
- `Legion::LLM::Discovery::Ollama` module — queries Ollama `/api/tags` for pulled models with TTL cache
- `Legion::LLM::Discovery::System` module — queries OS memory (macOS `vm_stat`/`sysctl`, Linux `/proc/meminfo`) with TTL cache
- Router step 4.5: rejects Ollama rules where model is not pulled or exceeds available memory
- Discovery settings: `enabled`, `refresh_seconds`, `memory_floor_mb` under `Legion::Settings[:llm][:discovery]`
- Startup discovery: logs available Ollama models and system memory when Ollama provider is enabled

### Changed
- Added SimpleCov for test coverage reporting

## [0.2.1]

### Added
- `Legion::LLM::Compressor` module for deterministic prompt compression
- Three compression levels: light (articles/filler), moderate (+connectives), aggressive (+low-signal words, whitespace collapse)
- Code block protection (fenced and inline code preserved)
- `compress_level` field on `Router::Resolution` for routing-driven compression
- `compress:` parameter on `llm_chat` helper for opt-in compression
- Routing rules can specify `compress_level` in target to auto-compress for cost-sensitive tiers

## [0.2.0]

### Added
- Dynamic weighted routing engine (`Legion::LLM::Router`)
- Intent-based dispatch with privacy, capability, and cost dimensions
- Priority-based rule matching with time-based schedule windows
- Cost multipliers for economic routing (e.g., provider promotions)
- HealthTracker with circuit breaker pattern and latency rolling window
- Pluggable signal handlers for extensible health monitoring
- `intent:` and `tier:` parameters on `chat`, `llm_chat`, and `llm_session`
- Routing rules configurable via `Legion::Settings[:llm][:routing]`
- Three-tier routing: local (Ollama), fleet (Transport/AMQP), cloud (API providers)

## v0.1.0
* Initial release
* Core module with start/shutdown lifecycle
* Provider configuration (Bedrock, Anthropic, OpenAI, Gemini, Ollama)
* Vault credential resolution for all providers
* Chat, embed, and agent convenience methods
* Extension helper mixin for LEX extensions
* Auto-detection of default model from enabled providers
