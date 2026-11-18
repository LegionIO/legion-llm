# frozen_string_literal: true

require 'stringio'
require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/api/stream_assembler'

RSpec.describe Legion::LLM::API::StreamAssembler do
  let(:canonical) { Legion::Extensions::Llm::Canonical }

  def sse_events(out)
    out.string.split("\n\n").filter_map do |event|
      data_line = event.lines.find { |line| line.start_with?('data: ') }
      next unless data_line

      Legion::JSON.load(data_line.delete_prefix('data: ').strip)
    end
  end

  def new_assembler(translator, out, request_id: 'stream_test', buffering: :unbuffered)
    emitter = translator.new.events_emitter(
      out, request_id: request_id, model: 'test-model'
    )
    described_class.new(
      emitter:             emitter,
      request_id:          request_id,
      model:               'test-model',
      tool_call_buffering: buffering,
      initial_lane:        { id: 'test:lane' }
    )
  end

  def tool_chunk(tool_call, request_id: 'stream_test', index: 0)
    canonical::Chunk.tool_call_delta(
      tool_call:  tool_call,
      request_id: request_id,
      index:      index
    )
  end

  def final_response(tool_calls)
    Legion::LLM::Inference::Response.build(
      request_id: 'stream_test', conversation_id: 'stream_conversation',
      message: { role: :assistant, content: '' }, tools: tool_calls,
      stop: { reason: :end_turn }, tokens: { input: 0, output: 0 },
      routing: { model: 'test-model' }
    )
  end

  it 'preserves identity and incremental argument strings from Hash fragments' do
    out = StringIO.new
    assembler = new_assembler(Legion::LLM::API::ClientTranslators::OpenAIResponses, out)

    assembler.push(tool_chunk(
                     { id: 'call_hash', name: 'lookup', arguments: '{"payload": ', index: 0 },
                     index: 0
                   ))
    assembler.push(tool_chunk(
                     { id: 'call_hash', arguments: '{"payload": 1}}', index: 0 },
                     index: 0
                   ))

    events = sse_events(out)
    call = events.find do |event|
      event[:type] == 'response.output_item.added' && event.dig(:item, :type) == 'function_call'
    end
    deltas = events.select do |event|
      event[:type] == 'response.function_call_arguments.delta' && event[:item_id] == 'call_hash'
    end

    expect(call.dig(:item, :id)).to eq('call_hash')
    expect(call.dig(:item, :call_id)).to eq('call_hash')
    expect(call.dig(:item, :name)).to eq('lookup')
    expect(deltas.map { |event| event[:delta] }.join).to eq('{"payload": {"payload": 1}}')
  end

  it 'maps parallel idless continuations by their provider indexes' do
    out = StringIO.new
    assembler = new_assembler(Legion::LLM::API::ClientTranslators::OpenAIResponses, out)

    assembler.push(tool_chunk(
                     { id: 'call_first', name: 'first', arguments: '{"a":', index: 0 }, index: 0
                   ))
    assembler.push(tool_chunk(
                     { id: 'call_second', name: 'second', arguments: '{"b":', index: 1 }, index: 1
                   ))
    assembler.push(tool_chunk(
                     { arguments: '1}', index: 0 }, index: 0
                   ))
    assembler.push(tool_chunk(
                     { arguments: '2}', index: 1 }, index: 1
                   ))

    events = sse_events(out)
    calls = events.select do |event|
      event[:type] == 'response.output_item.added' && event.dig(:item, :type) == 'function_call'
    end
    ids_by_name = calls.to_h { |event| [event.dig(:item, :name), event.dig(:item, :id)] }
    arguments_by_name = ids_by_name.to_h do |name, id|
      deltas = events.select do |event|
        event[:type] == 'response.function_call_arguments.delta' && event[:item_id] == id
      end
      [name, deltas.map { |event| event[:delta] }.join]
    end

    expect(ids_by_name).to eq('first' => 'call_first', 'second' => 'call_second')
    expect(arguments_by_name).to eq('first' => '{"a":1}', 'second' => '{"b":2}')
  end

  it 'does not alias an unknown index zero to the previous provider round' do
    out = StringIO.new
    assembler = new_assembler(Legion::LLM::API::ClientTranslators::OpenAIResponses, out)

    assembler.push(tool_chunk(
                     { id: 'call_old', name: 'old_lookup', arguments: '{"old":', index: 0 }, index: 0
                   ))
    assembler.provider_round_started
    assembler.push(tool_chunk(
                     { name: 'new_lookup', arguments: '{"new":', index: 0 }, index: 0
                   ))

    new_call = canonical::ToolCall.build(
      id: 'call_new', name: 'new_lookup', arguments: { new: 1 },
      source: :client, status: :pending
    )
    assembler.finalize(final_response([new_call]))

    events = sse_events(out)
    calls = events.select do |event|
      event[:type] == 'response.output_item.added' && event.dig(:item, :type) == 'function_call'
    end
    calls_by_name = calls.to_h { |event| [event.dig(:item, :name), event.dig(:item, :id)] }
    old_deltas = events.select do |event|
      event[:type] == 'response.function_call_arguments.delta' && event[:item_id] == 'call_old'
    end

    expect(calls_by_name['old_lookup']).to eq('call_old')
    expect(calls_by_name['new_lookup']).to eq('call_new')
    expect(calls_by_name.values.uniq.length).to eq(2)
    expect(old_deltas.map { |event| event[:delta] }.join).to eq('{"old":')
  end

  it 'uses the resolved server source when completion follows an unknown-source fragment' do
    out = StringIO.new
    assembler = new_assembler(Legion::LLM::API::ClientTranslators::OpenAIResponses, out)
    started = canonical::ToolCall.build(
      id: 'server_unknown', name: 'lookup', arguments: { query: 'alpha' },
      source: :registry, status: :running
    )
    completed = started.with_result(result: { answer: 'found' }, status: :success)

    assembler.push(tool_chunk(
                     { id: 'server_unknown', name: 'lookup', arguments: '{"query":"alpha"}', index: 0 },
                     index: 0
                   ))
    assembler.server_tool_started(tool_call: started)
    assembler.server_tool_completed(tool_call: completed)

    events = sse_events(out)
    call_events = events.select do |event|
      event[:type] == 'response.output_item.added' && event.dig(:item, :type) == 'function_call'
    end
    result_events = events.select do |event|
      event[:type] == 'response.output_item.added' && event.dig(:item, :type) == 'function_call_output'
    end

    expect(call_events.length).to eq(1)
    expect(result_events.length).to eq(1)

    expect(result_events.first.dig(:item, :call_id)).to eq('server_unknown')
    expect(result_events.first.dig(:item, :output)).to eq('{"answer":"found"}')
  end

  it 'emits a server call and result before finalize and never repeats either at finalize' do
    out = StringIO.new
    assembler = new_assembler(Legion::LLM::API::ClientTranslators::OpenAIResponses, out, buffering: :buffered)
    started = canonical::ToolCall.build(
      id: 'server_once', name: 'lookup', arguments: { query: 'alpha' },
      source: :registry, status: :running
    )
    completed = started.with_result(result: { answer: 'found' }, status: :success)

    assembler.server_tool_started(tool_call: started)
    assembler.server_tool_completed(tool_call: completed)
    before_finalize = sse_events(out)

    expect(before_finalize.any? do |event|
      event[:type] == 'response.output_item.added' && event.dig(:item, :type) == 'function_call'
    end).to be(true)
    expect(before_finalize.count do |event|
      event[:type] == 'response.output_item.added' && event.dig(:item, :type) == 'function_call_output'
    end).to eq(1)

    assembler.finalize(final_response([completed]))
    after_finalize = sse_events(out)

    expect(after_finalize.count do |event|
      event[:type] == 'response.output_item.added' && event.dig(:item, :type) == 'function_call'
    end).to eq(1)
    expect(after_finalize.count do |event|
      event[:type] == 'response.output_item.added' && event.dig(:item, :type) == 'function_call_output'
    end).to eq(1)
  end

  it 'does not fabricate a result for a client-owned tool call' do
    out = StringIO.new
    assembler = new_assembler(Legion::LLM::API::ClientTranslators::OpenAIResponses, out)
    client_call = canonical::ToolCall.build(
      id: 'client_once', name: 'weather', arguments: { city: 'Boston' },
      source: :client, status: :pending
    )

    assembler.push(tool_chunk(
                     { id: 'client_once', name: 'weather', arguments: '{"city":"Boston"}', source: :client, index: 0 },
                     index: 0
                   ))
    assembler.finalize(final_response([client_call]))

    events = sse_events(out)
    expect(events).not_to include(a_hash_including(
                                    type: 'response.output_item.added',
                                    item: a_hash_including(type: 'function_call_output')
                                  ))
  end

  it 'renders server lifecycle call and result through the real Anthropic emitter' do
    out = StringIO.new
    assembler = new_assembler(Legion::LLM::API::ClientTranslators::AnthropicMessages, out)
    started = canonical::ToolCall.build(
      id: 'anthropic_server', name: 'lookup', arguments: { query: 'alpha' },
      source: :extension, status: :running
    )
    completed = started.with_result(result: 'found', status: :success)

    assembler.server_tool_started(tool_call: started)
    assembler.server_tool_completed(tool_call: completed)
    before_finalize = sse_events(out)

    expect(before_finalize).to include(a_hash_including(
                                         type:          'content_block_start',
                                         content_block: a_hash_including(type: 'server_tool_use', id: 'anthropic_server', name: 'lookup')
                                       ))
    expect(before_finalize).to include(a_hash_including(
                                         type:          'content_block_start',
                                         content_block: a_hash_including(type: 'server_tool_result', id: 'anthropic_server')
                                       ))

    assembler.finalize(final_response([completed]))
    after_finalize = sse_events(out)
    expect(after_finalize.count do |event|
      event[:type] == 'content_block_start' && event.dig(:content_block, :type) == 'server_tool_use'
    end).to eq(1)
    expect(after_finalize.count do |event|
      event[:type] == 'content_block_start' && event.dig(:content_block, :type) == 'server_tool_result'
    end).to eq(1)
  end
end
