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
        if respond_to?(:set_prop)
          set_prop(key.to_sym, value)
        else
          @store[key.to_sym] = value
        end
      end

      def key?(key)
        if respond_to?(:get)
          get.settings.key?(key.to_sym) || get.settings.key?(key.to_s)
        else
          @store.key?(key.to_sym)
        end
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

require 'legion/json'
require_relative 'support/transport_stub'
require 'legion/llm'

RSpec.configure do |config|
  config.before(:each) do
    Legion::Settings.reset!
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::LLM::Call::Registry.reset! if defined?(Legion::LLM::Call::Registry)
    # Keep the full suite deterministic even when local/provider gems are present
    # and services like Ollama are running on the developer machine. Native-mode
    # specs opt back in explicitly.
    Legion::Settings[:llm][:provider_layer][:mode] = 'ruby_llm'
    # Disable system_baseline by default so existing pipeline mocks are unaffected.
    # Specs that test baseline behavior set it explicitly.
    Legion::Settings[:llm][:system_baseline] = nil
  end
end
