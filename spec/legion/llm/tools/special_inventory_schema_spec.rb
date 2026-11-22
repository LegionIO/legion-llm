# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/tools/mcp_execution'

RSpec.describe 'The zero-argument inventory tool MCP contract' do
  let(:definition) { Legion::LLM::Tools::Special.special_tools_definition }

  def execute(definition:, arguments:)
    Legion::LLM::Tools::MCPExecution.dispatch(
      tool_call: { id: 'call_inventory', name: definition.name, arguments: arguments },
      source: definition.source, definition: definition
    )
  end

  it 'executes the actual inventory handler once for an empty argument object' do
    expect(Legion::LLM::Tools::Special).to receive(:inventory).once.and_call_original

    result = execute(definition: definition, arguments: {})

    expect(result[:status]).to eq(:success)
    expect(Legion::JSON.load(result[:result])).to include(:counts, :special_tools, :settings_extensions_tools, :runtime)
  end

  it 'rejects undeclared properties in the real MCP SDK before dispatch' do
    expect(Legion::LLM::Tools::Dispatcher).not_to receive(:dispatch)
    expect(Legion::LLM::Tools::Special).not_to receive(:inventory)

    result = execute(definition: definition, arguments: { unexpected: 'value' })

    expect(result[:status]).to eq(:error)
    expect(result[:result]).to include('unexpected')
  end

  it 'preserves the supported filters on the other inventory tool' do
    other = Legion::LLM::Tools::Special.all_tools_definition
    expect(Legion::LLM::Tools::Special).to receive(:all_tools_inventory)
      .with(extension: 'schema_probe', deferred: false).once.and_call_original

    result = execute(definition: other, arguments: { extension: 'schema_probe', deferred: false })

    expect(result[:status]).to eq(:success)
    expect(Legion::JSON.load(result[:result])).to include(total: 0, extensions: {})
  end

  it 'does not close a caller-owned open argument object at the MCP boundary' do
    open_definition = Legion::Extensions::Llm::Canonical::ToolDefinition.build(
      name: 'open_record', parameters: { type: 'object', properties: {} }, source: { type: :registry }
    )
    expect(Legion::LLM::Tools::Dispatcher).to receive(:dispatch)
      .with(tool_call: { id: 'call_inventory', name: 'open_record', arguments: { custom: 'value' } },
            source: open_definition.source, exchange_id: nil).once.and_return(status: :success, result: 'accepted')

    expect(execute(definition: open_definition, arguments: { custom: 'value' })).to include(status: :success, result: 'accepted')
    expect(open_definition.parameters).not_to have_key(:additionalProperties)
  end
end
