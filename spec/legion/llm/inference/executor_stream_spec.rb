# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor, '#call_stream' do
  before do
    stub_native_provider(content: 'Hello there.')
  end

  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      stream:   true
    )
  end

  # SSOT v3: register a capturing callable for stream_chat that can yield chunks
  # and record the system/messages kwargs passed by the executor. Always resets
  # the Phase 1 Registry first so the custom callable replaces the stub default.
  def register_capturing_stream_callable(chunks: [], content: 'done', &capture_hook)
    Legion::Extensions::Llm::Inventory::Registry.reset!
    captured = {}
    result = native_dispatch_result(content: content)
    responder = proc do |_op, _args, kwargs, blk|
      capture_hook&.call(captured, kwargs)
      chunks.each { |c| blk&.call(c) }
      blk&.call(Struct.new(:content).new(content)) if chunks.empty?
      result
    end
    callable = SsotV3SnapshotFactory::FactoryCallable.new(responder: responder)
    SsotV3SnapshotFactory.activate(
      provider_family: 'vllm',
      instance_id:     'primary',
      callable:        callable,
      drafts:          [SsotV3SnapshotFactory.offering_draft(
        model:        SSOT_TEST_MODEL, tier: :local,
        supported:    %i[chat stream_chat count_tokens],
        capabilities: { streaming: :supported },
        context:      200_000, max_output: 16_384
      )]
    )
    captured
  end

  it 'yields chunks to the block' do
    chunk1 = Struct.new(:content).new('hello ')
    chunk2 = Struct.new(:content).new('world')
    captured = register_capturing_stream_callable(chunks: [chunk1, chunk2], content: 'hello world')
    executor = described_class.new(request)
    chunks = []

    response = executor.call_stream { |chunk| chunks << chunk }

    expect(chunks.map(&:content)).to eq(['hello ', 'world'])
    expect(response).to be_a(Legion::LLM::Inference::Response)
    _ = captured
  end

  it 'runs pre-provider steps before streaming' do
    executor = described_class.new(request)
    allow(executor).to receive(:step_provider_call_stream).and_return(nil)

    executor.call_stream { |_chunk| nil }

    expect(executor.tracing).not_to be_nil
    expect(executor.tracing[:trace_id]).to be_a(String)
  end

  it 'runs post-provider steps after stream completes' do
    executor = described_class.new(request)

    response = executor.call_stream { |_chunk| nil }

    timeline_keys = response.timeline.map { |e| e[:key] }
    expect(timeline_keys).to include('tracing:init')
  end

  it 'applies enriched system instructions before streaming the provider call' do
    req = Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      system:   'Base system prompt',
      stream:   true
    )
    executor = described_class.new(req)
    executor.enrichments['gaia:system_prompt'] = { content: 'Injected streaming guidance' }

    seen_system = nil
    register_capturing_stream_callable do |captured, kwargs|
      seen_system = kwargs[:system]
      captured[:system] = seen_system
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
      stream:   true
    )

    executor = described_class.new(req)
    seen_messages = nil
    register_capturing_stream_callable do |captured, kwargs|
      seen_messages = kwargs[:messages]
      captured[:messages] = seen_messages
    end

    executor.call_stream { |_chunk| nil }

    expect(seen_messages).to include(hash_including(role: :assistant, cache_control: { type: 'ephemeral' }))
  end

  it 'propagates provider errors as LLM errors when the callable raises during streaming' do
    # SSOT v3 invariant: a callable failure during streaming is classified by
    # OutcomeClassifier; when all lanes are exhausted a ProviderError or
    # RoutingRejected propagates — never a silent success.
    Legion::Extensions::Llm::Inventory::Registry.reset!
    error_callable = SsotV3SnapshotFactory::FactoryCallable.new(
      responder: proc { |_op, _args, _kwargs, _blk| raise Legion::Extensions::Llm::OverloadedError, 'provider overloaded' }
    )
    SsotV3SnapshotFactory.activate(
      provider_family: 'vllm',
      instance_id:     'primary',
      callable:        error_callable,
      drafts:          [SsotV3SnapshotFactory.offering_draft(
        model:     SSOT_TEST_MODEL, tier: :local,
        supported: %i[chat stream_chat count_tokens],
        context:   200_000, max_output: 16_384
      )]
    )

    executor = described_class.new(request)

    expect { executor.call_stream { |_chunk| nil } }.to raise_error(Legion::LLM::LLMError)
  end

  it 'falls back to blocking call when no block given' do
    executor = described_class.new(request)
    allow(executor).to receive(:step_provider_call)
    response = executor.call_stream
    expect(response).to be_a(Legion::LLM::Inference::Response)
  end
end
