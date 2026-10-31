# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

legion_settings_path = File.expand_path('../legion-settings', __dir__)
gem 'legion-settings', path: legion_settings_path if Dir.exist?(legion_settings_path)

group :test do
  # Immutable CI companions and adjacent development checkouts both consume the
  # shared contract directly. Standalone installs use the gemspec dependency.
  lex_llm_path = File.expand_path('.ci-dependencies/lex-llm', __dir__)
  lex_llm_path = File.expand_path('../extensions-ai/lex-llm', __dir__) unless Dir.exist?(lex_llm_path)
  gem 'lex-llm', path: lex_llm_path if Dir.exist?(lex_llm_path)

  # Execution regressions exercise real provider callables in every checkout.
  vllm_path = File.expand_path('.ci-dependencies/lex-llm-vllm', __dir__)
  vllm_path = File.expand_path('../extensions-ai/lex-llm-vllm', __dir__) unless Dir.exist?(vllm_path)
  if Dir.exist?(vllm_path)
    gem 'lex-llm-vllm', path: vllm_path
  else
    gem 'lex-llm-vllm', '>= 0.4.9'
  end

  openai_path = File.expand_path('../extensions-ai/lex-llm-openai', __dir__)
  if Dir.exist?(openai_path)
    gem 'lex-llm-openai', path: openai_path
  else
    gem 'lex-llm-openai', '>= 0.6.7'
  end

  %w[
    lex-llm-ollama
    lex-llm-anthropic
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
  rubocop_legion_path = File.expand_path('../rubocop-legion', __dir__)
  if Dir.exist?(rubocop_legion_path)
    gem 'rubocop-legion', path: rubocop_legion_path
  else
    # 0.1.8 is the first published release carrying the four Legion/Framework N×N guard
    # cops (incl. Legion/Framework/NoShapeDuckTyping, referenced in .rubocop.yml).
    gem 'rubocop-legion', '>= 0.1.8'
  end
  gem 'simplecov'
  gem 'sinatra'
  gem 'webmock'
end
