# Legion LLM Changelog

## [Unreleased]

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
