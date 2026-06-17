# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

legion_settings_path = File.expand_path('../legion-settings', __dir__)
gem 'legion-settings', path: legion_settings_path if Dir.exist?(legion_settings_path)

group :test do
  # The published lex-llm (>= 0.5.3, declared in the gemspec) provides the Canonical
  # types and fleet security behavior these specs require. Use the local checkout when
  # present (development); CI resolves the published gem via the gemspec dependency.
  lex_llm_path = File.expand_path('../extensions-ai/lex-llm', __dir__)
  gem 'lex-llm', path: lex_llm_path if Dir.exist?(lex_llm_path)

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
  rubocop_legion_path = File.expand_path('../rubocop-legion', __dir__)
  if Dir.exist?(rubocop_legion_path)
    gem 'rubocop-legion', path: rubocop_legion_path
  else
    # TEMP: the N×N guard cops (incl. Legion/Framework/NoShapeDuckTyping, referenced in
    # .rubocop.yml) are merged to rubocop-legion main but the published 0.1.7 predates
    # them. Track main until 0.1.8 publishes, then revert this whole branch to
    # `gem 'rubocop-legion', '>= 0.1.8'`.
    gem 'rubocop-legion', git: 'https://github.com/LegionIO/rubocop-legion.git', branch: 'main'
  end
  gem 'simplecov'
  gem 'sinatra'
  gem 'webmock'
end
