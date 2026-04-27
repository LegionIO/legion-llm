# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :test do
  gem 'lex-llm', git: 'https://github.com/LegionIO/lex-llm', branch: ENV.fetch('LEX_LLM_BRANCH', 'main')
  gem 'rake'
  gem 'rspec'
  gem 'rspec_junit_formatter'
  gem 'rubocop'
  gem 'rubocop-legion'
  gem 'simplecov'
  gem 'sinatra'
  gem 'webmock'
end
