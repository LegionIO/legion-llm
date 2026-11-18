# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/api/stream_assembler'

RSpec.describe 'Responses MCP execution contract' do
  let(:translator) { Legion::LLM::API::ClientTranslators::OpenAIResponses.new }
  let(:result) { Legion::JSON.dump({ entries: Array.new(1000, 'entry'), tail: 'inventory_end' }) }
  let(:call) do
    Legion::Extensions::Llm::Canonical::ToolCall.build(
      id: 'call_inventory', name: 'legion_list_all_tools', arguments: {}, source: :special,
      status: :running, metadata: { mcp_server_label: 'legion' }
    )
  end
  let(:completed) { call.with_result(result: result, status: :success) }

  def response_for(tool)
    Legion::LLM::Inference::Response.build(
      request_id: 'mcp_contract', conversation_id: 'mcp_conversation',
      message: { role: :assistant, content: 'Inventory checked.' }, tools: [tool],
      stop: { reason: :end_turn }, tokens: { input: 0, output: 0 }, routing: { model: 'test-model' }
    )
  end

  def events_from(out)
    out.string.lines.filter_map do |line|
      next unless line.start_with?('data: ')

      Legion::JSON.load(line.delete_prefix('data: '))
    end
  end

  it 'returns a documented server item carrying the full result and no client function' do
    wire = translator.format_response(response_for(completed), request_id: 'mcp_contract', model: 'test-model')
    item = wire[:output].find { |entry| entry[:type] == 'mcp_call' }

    expect(item).to include(id: call.id, name: call.name, server_label: 'legion', arguments: '{}',
                            status: 'completed', output: result, error: nil)
    expect(wire[:output].map { |entry| entry[:type] }).to eq(%w[mcp_call message])
    expect(wire[:output].last.dig(:content, 0, :text)).to eq('Inventory checked.')
  end

  %i[buffered unbuffered].each do |buffering|
    it "emits one ordered MCP lifecycle with #{buffering} streaming and final replay" do
      out = StringIO.new
      assembler = Legion::LLM::API::StreamAssembler.new(
        emitter: translator.events_emitter(out, request_id: 'mcp_contract', model: 'test-model'),
        request_id: 'mcp_contract', model: 'test-model', tool_call_buffering: buffering, initial_lane: { id: 'test:lane' }
      )
      assembler.server_tool_started(tool_call: call)
      expect(events_from(out).none? { |event| event[:type] == 'response.output_item.done' }).to be(true)
      assembler.server_tool_completed(tool_call: completed)
      assembler.finalize(response_for(completed))

      events = events_from(out)
      added = events.select { |event| event[:type] == 'response.output_item.added' && event.dig(:item, :type) == 'mcp_call' }
      done = events.select { |event| event[:type] == 'response.output_item.done' && event.dig(:item, :type) == 'mcp_call' }
      expect(added.size).to eq(1)
      expect(done.size).to eq(1)
      expect(done.first[:item]).to include(output: result, status: 'completed')
      expect(events.count { |event| event[:type] == 'response.mcp_call.completed' }).to eq(1)
      expect(events.map { |event| event[:sequence_number] }).to eq((1..events.size).to_a)
      expect(events.none? { |event| event.dig(:item, :type) == 'function_call' }).to be(true)
      expect(events.last.dig(:response, :output)).to include(done.first[:item])
    end
  end

  it 'round-trips completed server history into ordinary canonical provider call and result messages' do
    wire = translator.format_response(response_for(completed), request_id: 'mcp_contract', model: 'test-model')
    parsed = translator.parse_request(input: wire[:output] + [{ role: 'user', content: 'Continue.' }])

    restored = parsed.messages.first.tool_calls.first
    expect(restored).to have_attributes(id: call.id, name: call.name, source: :mcp, arguments: {}, result: result, status: :success)
    expect(restored.metadata).to include(mcp_server_label: 'legion')
    expect(parsed.messages[1]).to have_attributes(role: :tool, tool_call_id: call.id, content: result)
    expect(parsed.messages.last.content).to eq('Continue.')
  end

  it 'renders and restores failed calls as errors with their complete output' do
    failed = call.with_result(result: 'inventory unavailable', status: :error)
    wire = translator.format_response(response_for(failed), request_id: 'mcp_contract', model: 'test-model')
    item = wire[:output].first

    expect(item).to include(type: 'mcp_call', status: 'failed', output: 'inventory unavailable',
                            error: { type: 'mcp_tool_execution_error', content: 'inventory unavailable' })
    parsed = translator.parse_request(input: wire[:output])
    expect(parsed.messages.first.tool_calls.first.status).to eq(:error)
  end

  it 'keeps an executed MCP result complete when the following answer reaches its token limit' do
    response = response_for(completed).with(stop: { reason: :max_tokens })
    wire = translator.format_response(response, request_id: 'mcp_contract', model: 'test-model')
    out = StringIO.new
    assembler = Legion::LLM::API::StreamAssembler.new(
      emitter: translator.events_emitter(out, request_id: 'mcp_contract', model: 'test-model'),
      request_id: 'mcp_contract', model: 'test-model', initial_lane: { id: 'test:lane' }
    )
    assembler.server_tool_started(tool_call: call)
    assembler.server_tool_completed(tool_call: completed)
    assembler.finalize(response)

    events = events_from(out)
    expect(events.last[:type]).to eq('response.incomplete')
    [wire, events.last[:response]].each do |body|
      expect(body).to include(status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' })
      expect(body[:output]).to include(a_hash_including(type: 'mcp_call', status: 'completed', output: result))
    end
  end
end
