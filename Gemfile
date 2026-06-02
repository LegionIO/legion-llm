# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

legion_settings_path = File.expand_path('../legion-settings', __dir__)
gem 'legion-settings', path: legion_settings_path if Dir.exist?(legion_settings_path)

group :test do
  lex_llm_path = File.expand_path('../extensions-ai/lex-llm', __dir__)
  if Dir.exist?(lex_llm_path)
    gem 'lex-llm', path: lex_llm_path
  else
    # TEMP (revert to `gem 'lex-llm'` once 0.4.16 is published): track lex-llm PR #16, which
    # adds the fleet TokenValidator verify_issuer + WorkerExecution policy-warn behavior these specs require.
    gem 'lex-llm', git: 'https://github.com/LegionIO/lex-llm.git', branch: 'fix/audit-fleet-security'
  end

  %w[
    lex-llm-ollama
    lex-llm-vllm
    lex-llm-anthropic
    lex-llm-openai
    lex-llm-gemini
    lex-llm-mlx
    lex-llm-bedrock
    lex-llm-azure-foundry
    lex-llm-vertex
  ].each do |provider_gem|
    provider_path = File.expand_path("../extensions-ai/#{provider_gem}", __dir__)
    gem provider_gem, path: provider_path if Dir.exist?(provider_path)
  end

  gem 'rack-test', '~> 2.0'
  gem 'rake'
  gem 'rspec'
  gem 'rspec_junit_formatter'
  gem 'rubocop'
  gem 'rubocop-legion'
  gem 'simplecov'
  gem 'sinatra'
  gem 'webmock'
end
