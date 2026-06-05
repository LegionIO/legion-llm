# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::API::Translators::AnthropicResponse do
  let(:response) do
    instance_double(
      Legion::LLM::Inference::Response,
      message:  { content: 'visible text' },
      routing:  { model: 'qwen3.6-27b' },
      tokens:   { input: 12, output: 7 },
      tools:    [],
      stop:     { reason: 'end_turn' },
      thinking: { content: 'internal reasoning' }
    )
  end

  before do
    allow(response).to receive(:respond_to?).and_return(true)
  end

  it 'includes provider thinking as a thinking content block in non-streaming responses' do
    formatted = described_class.format(response, model: 'fallback-model', request_id: 'msg_test')

    expect(formatted[:content]).to eq([
      { type: 'thinking', thinking: 'internal reasoning' },
      { type: 'text', text: 'visible text' }
    ])
  end

  it 'does not expose provider thinking in complete streaming events' do
    events = described_class.streaming_events(response, model: 'fallback-model', request_id: 'msg_test', full_text: 'visible text')
    thinking_delta = events.find do |event_name, payload|
      event_name == 'content_block_delta' && payload[:delta][:type] == 'thinking_delta'
    end

    expect(thinking_delta).to be_nil
  end
end
