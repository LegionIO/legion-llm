# frozen_string_literal: true

require 'simplecov'
require 'base64'
ENV['LEGION_DNS_BOOTSTRAP'] = 'false'
SimpleCov.start do
  add_filter '/spec/'
end

require 'webmock/rspec'

require 'legion/logging'
Legion::Logging.setup(level: 'fatal', log_file: File::NULL, log_stdout: false, async: false, color: false)
require 'legion/settings'

require 'legion/json'
require_relative 'support/transport_stub'
require 'legion/llm'

def native_dispatch_result(content: 'test response', input_tokens: 10, output_tokens: 5, tool_calls: [])
  canonical = Legion::Extensions::Llm::Canonical
  usage = canonical::Usage.new(
    input_tokens: input_tokens, output_tokens: output_tokens,
    cache_read_tokens: 0, cache_write_tokens: 0, thinking_tokens: 0, units: {}
  )
  canonical_tool_calls = tool_calls.map do |tc|
    if tc.is_a?(canonical::ToolCall)
      tc
    else
      canonical::ToolCall.new(
        id: tc[:id] || "tc_#{SecureRandom.hex(4)}", exchange_id: nil,
        name: tc[:name].to_s, arguments: tc[:arguments] || {},
        source: tc[:source] || { type: :client }, status: tc[:status],
        duration_ms: nil, result: tc[:result], error: nil,
        started_at: nil, finished_at: nil, category: nil,
        data_handling_classification: nil, policy_decision: nil
      )
    end
  end
  stop = canonical_tool_calls.any? ? :tool_use : :end_turn
  canonical::Response.new(
    text: content.to_s, thinking: nil, tool_calls: canonical_tool_calls,
    usage: usage, stop_reason: stop, model: nil, routing: {}, metadata: {}
  )
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
    raw_hash = { content: content, usage: { input_tokens: input_tokens, output_tokens: output_tokens }, tool_calls: tool_calls }
    %i[anthropic test bedrock openai ollama vllm].each do |provider|
      Legion::LLM::Call::Registry.register(provider, Module.new do
        define_singleton_method(:chat) { |**| raw_hash }
        define_singleton_method(:stream) do |**, &block|
          block&.call(chunk)
          raw_hash
        end
        define_singleton_method(:embed) do |**|
          { result: [Array.new(1024, 0.1)], usage: { input_tokens: input_tokens, output_tokens: 0 } }
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
    Legion::Settings[:logging][:level] = :fatal
    Legion::LLM::Call::Registry.reset! if defined?(Legion::LLM::Call::Registry)
    # Re-register standard providers after reset so router resolution works
    if defined?(Legion::LLM::Call::Registry)
      %i[anthropic test bedrock openai ollama vllm azure_foundry gemini xai].each do |provider|
        Legion::LLM::Call::Registry.register(provider, Module.new) unless
          Legion::LLM::Call::Registry.registered?(provider)
      end
    end
    # Seed the extensions[:llm] path so specs can write provider configs there
    Legion::Settings[:extensions][:llm] ||= {}
    # Keep the full suite deterministic even when local/provider gems are present
    # and services like Ollama are running on the developer machine.
    Legion::Settings[:llm][:provider_layer][:mode] = 'auto'
    Legion::Settings[:llm][:pipeline_async_post_steps] = false
    # Disable system_baseline by default so existing pipeline mocks are unaffected.
    # Specs that test baseline behavior set it explicitly.
    Legion::Settings[:llm][:system_baseline] = nil
  end
end
