# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Dispatch contracts with initialized routing and real settings' do
  it 'preserves automatic choice and the caller list after a provider has been selected' do
    request = Legion::LLM::Inference::Request.build(
      messages:    [{ role: :user, content: 'Continue.' }],
      tools:       [Legion::LLM::Types::ToolDefinition.build(name: 'bash')],
      tool_choice: { mode: :auto, calls: %w[bash other_tool] }
    )
    executor = Legion::LLM::Inference::Executor.new(request)
    executor.instance_variable_set(:@resolved_provider, :anthropic)

    expect(executor.send(:native_tool_prefs)).to eq(choice: :auto, calls: %w[bash other_tool])
    expect(request.tool_choice).to eq(mode: :auto, calls: %w[bash other_tool])
  end

  it 'shares the historical text cap across cached blocks without altering media or current-turn results' do
    tools_settings = Legion::Settings[:llm][:tools]
    previous_limit = tools_settings[:result_max_dispatch_chars]
    tools_settings[:result_max_dispatch_chars] = 4
    canonical = Legion::Extensions::Llm::Canonical
    historical = canonical::Message.build(
      role: :tool, tool_call_id: 'historical-call',
      content: [
        { type: :text, text: 'ab', metadata: { origin: 'first' } },
        { type: :image, source_type: :url, data: 'https://example.com/image.png' },
        { type: :text, text: 'cdef', cache_control: { type: 'ephemeral' }, metadata: { origin: 'second' } },
        { type: :text, text: 'TAIL' }
      ]
    )
    current = historical.with(tool_call_id: 'current-call')
    user = canonical::Message.build(role: :user, content: 'Continue.')
    request = Legion::LLM::Inference::Request.build(messages: [historical, user, current])
    executor = Legion::LLM::Inference::Executor.new(request)
    original = Legion::JSON.dump(historical)

    result = executor.send(:trim_oversized_tool_results_pure, request.messages)

    expect(result.first.text.split("\n\n", 2).first).to eq('abcd')
    expect(result.first.text).not_to include('TAIL')
    expect(result.first.tool_call_id).to eq('historical-call')
    expect(result.first.content[0]).to equal(historical.content[0])
    expect(result.first.content[1]).to equal(historical.content[1])
    expect(result.first.content[2].cache_control).to eq(type: 'ephemeral')
    expect(result.first.content[2].metadata).to eq(origin: 'second')
    expect(result.last).to equal(current)
    expect(Legion::JSON.dump(historical)).to eq(original)
  ensure
    tools_settings[:result_max_dispatch_chars] = previous_limit if tools_settings
  end
end
