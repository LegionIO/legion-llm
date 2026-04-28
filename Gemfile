# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :test do
  lex_llm_path = File.expand_path('../extensions-ai/lex-llm', __dir__)
  if Dir.exist?(lex_llm_path)
    gem 'lex-llm', path: lex_llm_path
  else
    gem 'lex-llm'
  end

  %w[
    lex-llm-ollama
    lex-llm-vllm
    lex-llm-anthropic
    lex-llm-openai
    lex-llm-gemini
    lex-llm-mlx
  ].each do |provider_gem|
    provider_path = File.expand_path("../extensions-ai/#{provider_gem}", __dir__)
    gem provider_gem, path: provider_path if Dir.exist?(provider_path)
  end

  gem 'rake'
  gem 'rspec'
  gem 'rspec_junit_formatter'
  gem 'rubocop'
  gem 'rubocop-legion'
  gem 'simplecov'
  gem 'sinatra'
  gem 'webmock'
end
