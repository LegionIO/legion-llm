# frozen_string_literal: true

require 'stringio'
require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_chat'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/api/stream_assembler'

RSpec.describe 'Typed tool-argument snapshots on client streams' do
  def snapshot_events(output:)
    output.string.lines.filter_map do |line|
      next unless line.start_with?('data: ')
      next if line.strip == 'data: [DONE]'

      Legion::JSON.load(line.delete_prefix('data: '))
    end
  end

  def snapshot_argument_fragments(events:)
    events.flat_map do |event|
      if event[:type] == 'response.function_call_arguments.delta'
        [event[:delta]]
      elsif event.dig(:delta, :type) == 'input_json_delta'
        [event.dig(:delta, :partial_json)]
      else
        Array(event[:choices]).flat_map do |choice|
          Array(choice.dig(:delta, :tool_calls)).filter_map { |call| call.dig(:function, :arguments) }
        end
      end
    end
  end

  [Legion::LLM::API::ClientTranslators::AnthropicMessages,
   Legion::LLM::API::ClientTranslators::OpenAIChat,
   Legion::LLM::API::ClientTranslators::OpenAIResponses].each do |translator|
    it "completes #{translator.name.split('::').last} with the final snapshot rather than contradictory JSON deltas" do
      output = StringIO.new
      assembler = Legion::LLM::API::StreamAssembler.new(
        emitter: translator.new.events_emitter(output, request_id: 'snapshot-regression', model: 'test-model'),
        request_id: 'snapshot-regression', model: 'test-model', tool_call_buffering: :unbuffered,
        initial_lane: { id: 'test:lane' }
      )
      canonical = Legion::Extensions::Llm::Canonical
      partial = canonical::ToolCall.build(
        id: 'call_snapshot', name: 'bash', arguments: { command: 'ls' }, source: :client, status: :running
      )
      complete = partial.with(arguments: { command: 'ls -la' }, status: :pending)
      [partial, complete].each do |call|
        assembler.push(canonical::Chunk.tool_call_delta(tool_call: call, request_id: 'snapshot-regression', index: 0))
      end

      expect(snapshot_argument_fragments(events: snapshot_events(output: output)).join).to eq('')
      final_response = Legion::LLM::Inference::Response.build(
        request_id: 'snapshot-regression', conversation_id: 'snapshot-conversation',
        message: { role: :assistant, content: '' }, tools: [complete], stop: { reason: :tool_use },
        tokens: { input: 1, output: 1 }, routing: { model: 'test-model' }
      )
      assembler.finalize(final_response)

      events = snapshot_events(output: output)
      arguments = snapshot_argument_fragments(events: events).join
      expect(Legion::JSON.load(arguments)).to eq(command: 'ls -la')
      if translator == Legion::LLM::API::ClientTranslators::AnthropicMessages
        expect(events.last[:type]).to eq('message_stop')
        expect(events).to include(a_hash_including(type: 'content_block_stop'))
      elsif translator == Legion::LLM::API::ClientTranslators::OpenAIResponses
        expect(events.last[:type]).to eq('response.completed')
        expect(events.last.dig(:response, :status)).to eq('completed')
      else
        expect(events.last.dig(:choices, 0, :finish_reason)).to eq('tool_calls')
        expect(output.string).to include('data: [DONE]')
      end
    end
  end
end
