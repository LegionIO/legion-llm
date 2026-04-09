# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
end

require 'webmock/rspec'

# Stub Legion::Logging and Legion::Settings before loading legion-llm
module Legion
  module Logging
    class << self
      def debug(msg = nil); end
      def info(msg = nil); end
      def warn(msg = nil); end
      def error(msg = nil); end
      def fatal(msg = nil); end
    end
  end

  module Settings
    @store = {}

    class << self
      def [](key)
        @store[key.to_sym] ||= {}
      end

      def []=(key, value)
        @store[key.to_sym] = value
      end

      def key?(key)
        @store.key?(key.to_sym)
      end

      def dig(*keys)
        keys = keys.map(&:to_sym)
        result = @store
        keys.each do |k|
          return nil unless result.is_a?(Hash)

          result = result[k]
        end
        result
      end

      def merge_settings(key, defaults)
        current = @store[key.to_sym] || {}
        @store[key.to_sym] = defaults.merge(current)
      end

      def reset!
        @store = {}
      end
    end
  end
end

require_relative 'support/transport_stub'
require 'legion/llm'

RSpec.configure do |config|
  config.before(:each) do
    Legion::Settings.reset!
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
  end
end
