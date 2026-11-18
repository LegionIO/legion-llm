# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/tools/mcp_execution'

RSpec.describe Legion::LLM::Tools::MCPExecution do
  let(:source) { { type: :registry } }
  let(:definition) do
    Legion::LLM::Types::ToolDefinition.build(
      name: 'read_record', description: 'Read a record',
      parameters: { type: 'object', properties: { key: { type: 'string' } }, required: ['key'] }
    )
  end
  let(:tool_call) { { id: 'call_record', name: 'read_record', arguments: { key: 'one' } } }
  let(:dispatcher) { Legion::LLM::Tools::Dispatcher }

  it 'uses the local SDK adapter and executes the resolved handler exactly once' do
    result = "#{'record;' * 1200}record_end"
    expect(dispatcher).to receive(:dispatch).once.with(tool_call: tool_call, source: source, exchange_id: 'exchange')
                                            .and_return(status: :success, result: result, duration_ms: 4)

    actual = described_class.dispatch(tool_call: tool_call, source: source, definition: definition, exchange_id: 'exchange')

    expect(actual).to include(status: :success, result: result, duration_ms: 4)
    expect(described_class.metadata_for(source)).to eq(mcp_server_label: 'legion')
  end

  it 'rejects invalid arguments at the MCP boundary before the handler runs' do
    expect(dispatcher).not_to receive(:dispatch)

    actual = described_class.dispatch(tool_call: tool_call.merge(arguments: {}), source: source, definition: definition)

    expect(actual[:status]).to eq(:error)
    expect(actual[:result]).to include('key')
  end

  it 'preserves execution failures instead of turning a protocol response into success' do
    expect(dispatcher).to receive(:dispatch).once.and_return(status: :error, result: 'record unavailable')

    actual = described_class.dispatch(tool_call: tool_call, source: source, definition: definition)

    expect(actual).to include(status: :error, result: 'record unavailable')
  end

  it 'preserves false as an actual result' do
    expect(dispatcher).to receive(:dispatch).once.and_return(status: :success, result: false)

    actual = described_class.dispatch(tool_call: tool_call, source: source, definition: definition)

    expect(actual[:result]).to eq('false')
  end

  it 'keeps an existing remote MCP source on its existing dispatcher' do
    remote = { type: :mcp, server: 'records' }
    expect(dispatcher).to receive(:dispatch).once.with(tool_call: tool_call, source: remote, exchange_id: nil)
                                            .and_return(status: :success, result: 'remote result')

    expect(described_class.dispatch(tool_call: tool_call, source: remote, definition: nil)).to include(result: 'remote result')
    expect(described_class.metadata_for(remote)).to eq(mcp_server_label: 'records')
  end
end
