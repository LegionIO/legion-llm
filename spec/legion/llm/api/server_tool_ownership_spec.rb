# frozen_string_literal: true

require 'stringio'
require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/api/client_translators/openai_chat'
require 'legion/llm/api/stream_assembler'

# A completed function_call is still a request for client execution. These
# checks model the client execution queue, rather than assuming that pairing a
# function_call with a function_call_output makes the call non-actionable.
RSpec.describe 'Server tool execution ownership at the client boundary' do
  let(:server_call) do
    Legion::Extensions::Llm::Canonical::ToolCall.build(
      id: 'call_inventory', name: 'legion_list_all_tools', arguments: {},
      source: :special, status: :running
    )
  end
  let(:result) { "inventory:#{'entry;' * 1000}inventory_end" }
  let(:completed_call) { server_call.with_result(result: result, status: :success) }
  let(:client_call) do
    Legion::Extensions::Llm::Canonical::ToolCall.build(
      id: 'call_client', name: 'client_lookup', arguments: { query: 'test' },
      source: :client, status: :pending
    )
  end

  def events_from(out)
    out.string.lines.filter_map do |line|
      next unless line.start_with?('data: ')

      data = line.delete_prefix('data: ').strip
      next if data == '[DONE]'

      Legion::JSON.load(data)
    end
  end

  def values_in(value)
    case value
    when Hash then value.values.flat_map { |child| values_in(child) }
    when Array then value.flat_map { |child| values_in(child) }
    when String then [value]
    else []
    end
  end

  def executable_call_ids(events, dialect)
    case dialect
    when :messages
      events.filter_map do |event|
        block = event[:content_block]
        block[:id] if event[:type] == 'content_block_start' && block[:type] == 'tool_use'
      end
    when :responses
      events.filter_map do |event|
        item = event[:item]
        item[:call_id] if %w[response.output_item.added response.output_item.done].include?(event[:type]) && item[:type] == 'function_call'
      end
    when :chat
      events.flat_map { |event| event.fetch(:choices, []).flat_map { |choice| choice.fetch(:delta, {}).fetch(:tool_calls, []) } }
            .filter_map { |call| call[:id] }
    end.uniq
  end

  {
    messages:  Legion::LLM::API::ClientTranslators::AnthropicMessages,
    responses: Legion::LLM::API::ClientTranslators::OpenAIResponses,
    chat:      Legion::LLM::API::ClientTranslators::OpenAIChat
  }.each do |dialect, translator|
    context dialect do
      %i[buffered unbuffered].each do |buffering|
        it "preserves visible server ownership with #{buffering} streaming", :aggregate_failures do
          out = StringIO.new
          emitter = translator.new.events_emitter(out, request_id: 'ownership_test', model: 'test-model')
          assembler = Legion::LLM::API::StreamAssembler.new(
            emitter: emitter, request_id: 'ownership_test', model: 'test-model',
            tool_call_buffering: buffering, initial_lane: { id: 'test:lane' }
          )
          assembler.push(Legion::Extensions::Llm::Canonical::Chunk.tool_call_delta(
                           tool_call: { id: server_call.id, name: server_call.name, arguments: '{}', index: 0 },
                           request_id: 'ownership_test', index: 0
                         ))
          expect(executable_call_ids(events_from(out), dialect)).to be_empty
          assembler.server_tool_started(tool_call: server_call)
          assembler.server_tool_completed(tool_call: completed_call)
          assembler.finalize(Legion::LLM::Inference::Response.build(
                               request_id: 'ownership_test', conversation_id: 'ownership_conversation',
                               message: { role: :assistant, content: 'Inventory checked.' },
                               tools: [completed_call, client_call], stop: { reason: :tool_use },
                               tokens: { input: 0, output: 0 }, routing: { model: 'test-model' }
                             ))

          events = events_from(out)
          visible = values_in(events).join("\n")
          expect(executable_call_ids(events, dialect)).to eq(['call_client'])
          expect(visible).to include(server_call.id, server_call.name, result)
          expect(completed_call.source).to eq(:special)
          expect(completed_call.arguments).to eq({})
          expect(completed_call.result).to eq(result)
        end
      end

      it 'preserves visible server ownership in a non-streaming mixed response', :aggregate_failures do
        response = Legion::LLM::Inference::Response.build(
          request_id: 'ownership_test', conversation_id: 'ownership_conversation',
          message: { role: :assistant, content: 'Inventory checked.' }, tools: [completed_call, client_call],
          stop: { reason: :tool_use }, tokens: { input: 0, output: 0 }, routing: { model: 'test-model' }
        )
        formatted = translator.new.format_response(response, request_id: 'ownership_test', model: 'test-model')
        calls = case dialect
                when :messages then formatted[:content].select { |block| block[:type] == 'tool_use' }.map { |block| block[:id] }
                when :responses then formatted[:output].select { |item| item[:type] == 'function_call' }.map { |item| item[:call_id] }
                when :chat then formatted[:choices].first[:message].fetch(:tool_calls, []).map { |call| call[:id] }
                end

        expect(calls).to eq(['call_client'])
        expect(values_in(formatted).join("\n")).to include(server_call.id, server_call.name, result, 'Inventory checked.')
      end
    end
  end
end
