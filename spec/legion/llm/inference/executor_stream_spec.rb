# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor, '#call_stream' do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
      stream:   true
    )
  end

  def register_native_stream(provider = :anthropic, &handler)
    Legion::LLM::Call::Registry.register(provider, Module.new do
      define_singleton_method(:stream) do |model:, messages:, **opts, &block|
        handler.call(model: model, messages: messages, block: block, **opts)
      end
    end)
  end

  it 'yields chunks to the block' do
    register_native_stream do |block:, **|
      block&.call('hello ')
      block&.call('world')
      { content: 'hello world', usage: { input_tokens: 10, output_tokens: 5 } }
    end
    executor = described_class.new(request)
    chunks = []

    response = executor.call_stream { |chunk| chunks << chunk }

    expect(chunks).to eq(['hello ', 'world'])
    expect(response).to be_a(Legion::LLM::Inference::Response)
  end

  it 'runs pre-provider steps before streaming' do
    executor = described_class.new(request)
    allow(executor).to receive(:step_provider_call_stream).and_return(nil)

    executor.call_stream { |_chunk| nil }

    expect(executor.tracing).not_to be_nil
    expect(executor.tracing[:trace_id]).to be_a(String)
  end

  it 'runs post-provider steps after stream completes' do
    register_native_stream { { content: 'done', usage: { input_tokens: 5, output_tokens: 3 } } }
    executor = described_class.new(request)

    response = executor.call_stream { |_chunk| nil }

    timeline_keys = response.timeline.map { |e| e[:key] }
    expect(timeline_keys).to include('tracing:init')
  end

  it 'applies enriched system instructions before streaming the provider call' do
    req = Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      system:   'Base system prompt',
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
      stream:   true
    )
    executor = described_class.new(req)
    executor.enrichments['gaia:system_prompt'] = { content: 'Injected streaming guidance' }

    seen_system = nil
    register_native_stream do |system:, **|
      seen_system = system
      { content: 'done', usage: { input_tokens: 5, output_tokens: 3 } }
    end

    executor.call_stream { |_chunk| nil }

    expect(seen_system).to include('Base system prompt', 'Injected streaming guidance')
  end

  it 'applies conversation breakpoints before streaming the provider call' do
    Legion::Settings[:llm][:prompt_caching][:enabled] = true
    Legion::Settings[:llm][:prompt_caching][:cache_conversation] = true

    req = Legion::LLM::Inference::Request.build(
      messages: [
        { role: :user, content: 'first message' },
        { role: :assistant, content: 'prior answer' },
        { role: :user, content: 'latest request' }
      ],
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
      stream:   true
    )

    executor = described_class.new(req)
    seen_messages = nil
    register_native_stream do |messages:, **|
      seen_messages = messages
      { content: 'done', usage: { input_tokens: 5, output_tokens: 3 } }
    end

    executor.call_stream { |_chunk| nil }

    expect(seen_messages).to include(hash_including(role: :assistant, cache_control: { type: 'ephemeral' }))
  end

  it 'uses Legion::LLM::Call::Dispatch for streaming when the provider layer selects native mode' do
    Legion::Settings[:llm][:provider_layer] = {
      mode: 'native'
    }
    Legion::LLM::Call::Registry.register(:anthropic, Module.new do
      define_singleton_method(:stream) do |model:, messages:, **, &block|
        block&.call('native ')
        block&.call('stream')
        {
          content:  "native stream #{model} #{messages.size}",
          usage:    { input_tokens: 8, output_tokens: 4 },
          metadata: { offering: { offering_id: 'anthropic:test:chat:claude-opus-4-6' } }
        }
      end
    end)

    executor = described_class.new(request)
    chunks = []

    response = executor.call_stream { |chunk| chunks << chunk }

    expect(chunks).to eq(['native ', 'stream'])
    expect(response.message[:content]).to eq('native stream claude-opus-4-6 1')
    expect(response.tokens[:input_tokens]).to eq(8)
    expect(response.routing[:offering_id]).to eq('anthropic:test:chat:claude-opus-4-6')
  end

  it 'raises when native streaming dispatch fails' do
    Legion::Settings[:llm][:provider_layer] = {
      mode: 'native'
    }
    Legion::LLM::Call::Registry.register(:anthropic, Module.new do
      define_singleton_method(:stream) do |**|
        raise Legion::LLM::ProviderError, 'native stream unavailable'
      end
    end)

    executor = described_class.new(request)

    expect { executor.call_stream { |_chunk| nil } }.to raise_error(Legion::LLM::ProviderError, /native stream unavailable/)
  end

  it 'falls back to blocking call when no block given' do
    executor = described_class.new(request)
    allow(executor).to receive(:step_provider_call)
    response = executor.call_stream
    expect(response).to be_a(Legion::LLM::Inference::Response)
  end
end
