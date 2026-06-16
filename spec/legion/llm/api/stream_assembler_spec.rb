# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/api/stream_assembler'

RSpec.describe Legion::LLM::API::StreamAssembler do
  def parse_sse_events(body)
    body.split("\n\n").filter_map do |event|
      data_line = event.lines.find { |line| line.start_with?('data: ') }
      next unless data_line

      Legion::JSON.load(data_line.delete_prefix('data: ').strip)
    end
  end

  it 'unwraps canonical content blocks when emitting fallback Responses text' do
    out = +''
    emitter = Legion::LLM::API::ClientTranslators::OpenAIResponses.new.events_emitter(
      out,
      request_id: 'resp_test',
      model:      'gemma-4-31b-it'
    )
    assembler = described_class.new(
      emitter:    emitter,
      request_id: 'resp_test',
      model:      'gemma-4-31b-it'
    )
    response = ::Struct.new(:message, :tools, :stop, :tokens, :routing, keyword_init: true).new(
      message: {
        role:    :assistant,
        content: [
          Legion::Extensions::Llm::Canonical::ContentBlock.text('stream fallback answer')
        ]
      },
      tools:   [],
      stop:    { reason: :end_turn },
      tokens:  { input_tokens: 3, output_tokens: 4 },
      routing: { model: 'gemma-4-31b-it' }
    )

    assembler.finalize(response)

    text_events = parse_sse_events(out).select { |payload| payload[:type] == 'response.output_text.delta' }
    expect(text_events.map { |payload| payload[:delta] }.join).to eq('stream fallback answer')
    expect(out).not_to include('Legion::Extensions::Llm::Canonical::ContentBlock')
  end
end
