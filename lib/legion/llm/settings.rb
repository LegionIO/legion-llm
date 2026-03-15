# frozen_string_literal: true

module Legion
  module LLM
    module Settings
      def self.default
        {
          enabled:          true,
          connected:        false,
          default_model:    nil,
          default_provider: nil,
          providers:        providers,
          routing:          routing_defaults
        }
      end

      def self.routing_defaults
        {
          enabled:        false,
          default_intent: { privacy: 'normal', capability: 'moderate', cost: 'normal' },
          tiers:          {
            local: { provider: 'ollama' },
            fleet: { queue: 'llm.inference', timeout_seconds: 30 },
            cloud: { providers: %w[bedrock anthropic] }
          },
          health:         {
            window_seconds:               300,
            circuit_breaker:              { failure_threshold: 3, cooldown_seconds: 60 },
            latency_penalty_threshold_ms: 5000,
            budget:                       { daily_limit_usd: nil, monthly_limit_usd: nil }
          },
          rules:          []
        }
      end

      def self.providers
        {
          bedrock:   {
            enabled:       false,
            default_model: 'us.anthropic.claude-sonnet-4-6-v1',
            api_key:       nil,
            secret_key:    nil,
            session_token: nil,
            bearer_token:  nil,
            region:        'us-east-2',
            vault_path:    nil
          },
          anthropic: {
            enabled:       false,
            default_model: 'claude-sonnet-4-6',
            api_key:       nil,
            vault_path:    nil
          },
          openai:    {
            enabled:       false,
            default_model: 'gpt-4o',
            api_key:       nil,
            vault_path:    nil
          },
          gemini:    {
            enabled:       false,
            default_model: 'gemini-2.0-flash',
            api_key:       nil,
            vault_path:    nil
          },
          ollama:    {
            enabled:       false,
            default_model: 'llama3',
            base_url:      'http://localhost:11434'
          }
        }
      end
    end
  end
end

begin
  Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default) if Legion.const_defined?('Settings')
rescue StandardError => e
  if Legion.const_defined?('Logging') && Legion::Logging.respond_to?(:fatal)
    Legion::Logging.fatal(e.message)
    Legion::Logging.fatal(e.backtrace)
  else
    puts e.message
    puts e.backtrace
  end
end
