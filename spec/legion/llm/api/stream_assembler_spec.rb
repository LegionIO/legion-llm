# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/stream_assembler'

RSpec.describe Legion::LLM::API::StreamAssembler do
  def parse_sse_events(body)
    body.split("\n\n").filter_map do |event|
      data_line = event.lines.find { |line| line.start_with?('data: ') }
      next unless data_line

      Legion::JSON.load(data_line.delete_prefix('data: ').strip)
    end
  end

  # Regression: a streamed legacy lex-llm Chunk carrying a legacy
  # Legion::Extensions::Llm::Thinking object (attr_reader :text/:signature, NO
  # .content) must surface its thinking TEXT on the wire — never the Ruby
  # `#<...Thinking:0x...>` inspect string. (Claude-Code /v1/messages leak.)
  it 'unwraps a legacy lex-llm Thinking object on a streamed chunk' do
    out = +''
    emitter = Legion::LLM::API::ClientTranslators::AnthropicMessages.new.events_emitter(
      out, request_id: 'msg_test', model: 'gemma-4-31b-it'
    )
    assembler = described_class.new(
      emitter: emitter, request_id: 'msg_test', model: 'gemma-4-31b-it', emit_thinking_blocks: true,
      initial_lane: { id: 'test:pending' }
    )

    legacy_thinking = Legion::Extensions::Llm::Thinking.new(text: 'the model reasoning', signature: nil)
    legacy_chunk = Struct.new(:content, :thinking, :tool_calls, :model_id,
                              :input_tokens, :output_tokens, :raw, keyword_init: true).new(
                                content: 'visible answer', thinking: legacy_thinking, tool_calls: nil,
                                model_id: 'gemma-4-31b-it', input_tokens: nil, output_tokens: nil, raw: nil
                              )

    assembler.push(legacy_chunk)

    expect(out).to include('the model reasoning')
    expect(out).not_to include('Legion::Extensions::Llm::Thinking')
    expect(out).not_to include(':0x')
  end

  # Regression: a canonical text_delta chunk whose delta arrives as a
  # ContentBlock (or array of them) — the post-tool-call final message shape —
  # must surface its TEXT, never `[#<data ...ContentBlock...>]`. (Codex
  # /v1/responses leak, image #51.)
  it 'unwraps a ContentBlock-array text_delta on the streamed wire' do
    out = +''
    emitter = Legion::LLM::API::ClientTranslators::OpenAIResponses.new.events_emitter(
      out, request_id: 'resp_test', model: 'gemma-4-31b-it'
    )
    assembler = described_class.new(emitter: emitter, request_id: 'resp_test', model: 'gemma-4-31b-it',
                                    initial_lane: { id: 'test:pending' })

    block = Legion::Extensions::Llm::Canonical::ContentBlock.text('4215 files in LegionIO')
    chunk = Legion::Extensions::Llm::Canonical::Chunk.text_delta(delta: [block], request_id: 'resp_test')
    assembler.push(chunk)

    expect(out).to include('4215 files in LegionIO')
    expect(out).not_to include('ContentBlock')
    expect(out).not_to include(':0x')
  end

  it 'unwraps canonical content blocks when emitting fallback Responses text' do
    out = +''
    emitter = Legion::LLM::API::ClientTranslators::OpenAIResponses.new.events_emitter(
      out,
      request_id: 'resp_test',
      model:      'gemma-4-31b-it'
    )
    assembler = described_class.new(
      emitter:      emitter,
      request_id:   'resp_test',
      model:        'gemma-4-31b-it',
      initial_lane: { id: 'test:pending' }
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
