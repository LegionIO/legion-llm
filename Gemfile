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

  gem 'rake'
  gem 'rspec'
  gem 'rspec_junit_formatter'
  gem 'rubocop'
  gem 'rubocop-legion'
  gem 'simplecov'
  gem 'sinatra'
  gem 'webmock'
end
