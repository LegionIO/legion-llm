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

      def register_library(key, defaults)
        sym = key.to_sym
        return if @registered_libraries&.include?(sym)

        merge_settings(sym, defaults)
        (@registered_libraries ||= []) << sym
      end

      def reset!
        @store = {}
        @registered_libraries = []
      end
    end
  end
end

require 'legion/json'
require_relative 'support/transport_stub'
require 'legion/llm'

def native_dispatch_result(content: 'test response', input_tokens: 10, output_tokens: 5, tool_calls: [])
  {
    result:     content,
    usage:      {
      input_tokens:  input_tokens,
      output_tokens: output_tokens
    },
    tool_calls: tool_calls
  }
end

def stub_native_provider(content: 'test response', input_tokens: 10, output_tokens: 5, tool_calls: [], available: true)
  result = native_dispatch_result(
    content:       content,
    input_tokens:  input_tokens,
    output_tokens: output_tokens,
    tool_calls:    tool_calls
  )

  allow(Legion::LLM::Call::Dispatch).to receive(:available?).and_return(available)
  allow(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat).and_return(result)
  allow(Legion::LLM::Call::Dispatch).to receive(:dispatch_stream) do |**_, &block|
    block&.call(double('NativeChunk', content: content))
    result
  end
  if defined?(Legion::LLM::Call::Registry)
    %i[anthropic test bedrock openai ollama].each do |provider|
      Legion::LLM::Call::Registry.register(provider, Module.new do
        define_singleton_method(:chat) { |**| result }
        define_singleton_method(:stream) do |**, &block|
          block&.call(double('NativeChunk', content: content))
          result
        end
        define_singleton_method(:embed) do |**|
          { result: [Array.new(1024, 0.1)], usage: Legion::LLM::Usage.new(input_tokens: input_tokens) }
        end
      end)
    end
  end
  result
end

RSpec.configure do |config|
  config.before(:each) do
    Legion::Settings.reset!
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::LLM::Call::Registry.reset! if defined?(Legion::LLM::Call::Registry)
    # Keep the full suite deterministic even when local/provider gems are present
    # and services like Ollama are running on the developer machine.
    Legion::Settings[:llm][:provider_layer][:mode] = 'auto'
    # Disable system_baseline by default so existing pipeline mocks are unaffected.
    # Specs that test baseline behavior set it explicitly.
    Legion::Settings[:llm][:system_baseline] = nil
  end
end
