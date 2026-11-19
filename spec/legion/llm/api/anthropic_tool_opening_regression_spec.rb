# frozen_string_literal: true

require 'stringio'
require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/stream_assembler'

RSpec.describe 'Anthropic streamed tool input boundaries' do
  def opening_events(output:)
    output.string.lines.filter_map do |line|
      Legion::JSON.load(line.delete_prefix('data: ')) if line.start_with?('data: ')
    end
  end

  { snapshot: { command: 'ls' }, json_fragment: '{"command":"' }.each do |kind, arguments|
    it "opens with an empty input object before delivering #{kind} arguments through deltas" do
      output = StringIO.new
      translator = Legion::LLM::API::ClientTranslators::AnthropicMessages.new
      assembler = Legion::LLM::API::StreamAssembler.new(
        emitter: translator.events_emitter(output, request_id: 'opening-regression', model: 'test-model'),
        request_id: 'opening-regression', model: 'test-model', tool_call_buffering: :unbuffered,
        initial_lane: { id: 'test:lane' }
      )
      canonical = Legion::Extensions::Llm::Canonical
      assembler.push(canonical::Chunk.tool_call_delta(
                       tool_call: { id: 'call_opening', name: 'bash', arguments: arguments, source: :client },
                       request_id: 'opening-regression', index: 0
                     ))

      opening = opening_events(output: output).find { |event| event[:type] == 'content_block_start' }
      expect(opening.fetch(:content_block)).to include(type: 'tool_use', id: 'call_opening', name: 'bash', input: {})

      complete = canonical::ToolCall.build(
        id: 'call_opening', name: 'bash', arguments: { command: 'ls -la' }, source: :client, status: :pending
      )
      response = Legion::LLM::Inference::Response.build(
        request_id: 'opening-regression', conversation_id: 'opening-conversation',
        message: { role: :assistant, content: '' }, tools: [complete], stop: { reason: :tool_use },
        tokens: { input: 1, output: 1 }, routing: { model: 'test-model' }
      )
      assembler.finalize(response)

      events = opening_events(output: output)
      fragments = events.filter_map do |event|
        event.dig(:delta, :partial_json) if event.dig(:delta, :type) == 'input_json_delta'
      end
      expect(Legion::JSON.load(fragments.join)).to eq(command: 'ls -la')
      expect(events.last[:type]).to eq('message_stop')
    end
  end
end
