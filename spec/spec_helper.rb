# frozen_string_literal: true

require 'simplecov'
require 'base64'
SimpleCov.start do
  add_filter '/spec/'
end

require 'webmock/rspec'

require 'legion/logging'
Legion::Logging.setup(level: 'error')
require 'legion/settings'

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
  chunk = Struct.new(:content).new(content)
  result = native_dispatch_result(
    content:       content,
    input_tokens:  input_tokens,
    output_tokens: output_tokens,
    tool_calls:    tool_calls
  )

  allow(Legion::LLM::Call::Dispatch).to receive(:available?).and_return(available)
  allow(Legion::LLM::Call::Dispatch).to receive(:dispatch_chat).and_return(result)
  allow(Legion::LLM::Call::Dispatch).to receive(:dispatch_stream) do |**_, &block|
    block&.call(chunk)
    result
  end
  allow(Legion::LLM::Call::Dispatch).to receive(:call).and_call_original
  if defined?(Legion::LLM::Call::Registry)
    %i[anthropic test bedrock openai ollama].each do |provider|
      Legion::LLM::Call::Registry.register(provider, Module.new do
        define_singleton_method(:chat) { |**| result }
        define_singleton_method(:stream) do |**, &block|
          block&.call(chunk)
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
    Legion::Settings.merge_settings('transport', Legion::Transport::Settings.default) if
      defined?(Legion::Transport::Settings)
    Legion::LLM::Call::Registry.reset! if defined?(Legion::LLM::Call::Registry)
    # Seed the extensions[:llm] path so specs can write provider configs there
    Legion::Settings[:extensions][:llm] ||= {}
    # Keep the full suite deterministic even when local/provider gems are present
    # and services like Ollama are running on the developer machine.
    Legion::Settings[:llm][:provider_layer][:mode] = 'auto'
    # Disable system_baseline by default so existing pipeline mocks are unaffected.
    # Specs that test baseline behavior set it explicitly.
    Legion::Settings[:llm][:system_baseline] = nil
  end
end
