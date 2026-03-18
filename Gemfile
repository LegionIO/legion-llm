# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'lex-llm-gateway', path: '../extensions-core/lex-llm-gateway' if File.directory?('../extensions-core/lex-llm-gateway')

group :test do
  gem 'rake'
  gem 'rspec'
  gem 'rspec_junit_formatter'
  gem 'rubocop'
  gem 'simplecov'
  gem 'webmock'
end
