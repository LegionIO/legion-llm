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

  it 'yields chunks to the block' do
    executor = described_class.new(request)
    chunks = []

    mock_session = double('session', with_tool: nil)
    allow(RubyLLM).to receive(:chat).and_return(mock_session)

    mock_response = double('response', content: 'hello world', input_tokens: 10, output_tokens: 5)
    allow(mock_session).to receive(:ask).and_yield('hello ').and_yield('world').and_return(mock_response)

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
    executor = described_class.new(request)
    mock_session = double('session', with_tool: nil)
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    mock_response = double('response', content: 'done', input_tokens: 5, output_tokens: 3)
    allow(mock_session).to receive(:ask).and_return(mock_response)

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

    mock_session = double('session')
    mock_response = double('response', content: 'done', input_tokens: 5, output_tokens: 3)
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    allow(mock_session).to receive(:with_tool).and_return(mock_session)
    allow(mock_session).to receive(:with_instructions).and_return(mock_session)
    allow(mock_session).to receive(:add_message)
    allow(mock_session).to receive(:ask).and_return(mock_response)

    expect(mock_session).to receive(:with_instructions).with(
      a_string_including('Base system prompt', 'Injected streaming guidance')
    ).and_return(mock_session)

    executor.call_stream { |_chunk| nil }
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
    mock_session = double('session')
    mock_response = double('response', content: 'done', input_tokens: 5, output_tokens: 3)
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
    allow(mock_session).to receive(:with_tool).and_return(mock_session)
    allow(mock_session).to receive(:with_instructions).and_return(mock_session)
    allow(mock_session).to receive(:add_message)
    allow(mock_session).to receive(:ask).and_return(mock_response)

    executor.call_stream { |_chunk| nil }

    expect(mock_session).to have_received(:add_message).with(
      hash_including(role: :assistant, cache_control: { type: 'ephemeral' })
    )
  end

  it 'falls back to blocking call when no block given' do
    executor = described_class.new(request)
    allow(executor).to receive(:step_provider_call)
    response = executor.call_stream
    expect(response).to be_a(Legion::LLM::Inference::Response)
  end
end
