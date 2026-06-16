# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_chat'

RSpec.describe 'canonical content block client formatting' do
  fake_response_class = Struct.new(:thinking, :routing, :tokens, :message, :tools, :stop, keyword_init: true)

  let(:canonical_block) { Legion::Extensions::Llm::Canonical::ContentBlock.text('visible answer') }
  let(:pipeline_response) do
    fake_response_class.new(
      thinking: nil,
      routing:  { model: 'fake-default' },
      tokens:   { input_tokens: 10, output_tokens: 20 },
      message:  { role: :assistant, content: [canonical_block] },
      tools:    [],
      stop:     { reason: :end_turn }
    )
  end

  it 'does not leak Ruby canonical object inspect strings through Anthropic Messages responses' do
    body = Legion::LLM::API::ClientTranslators::AnthropicMessages.new.format_response(
      pipeline_response,
      model:      'fake-default',
      request_id: 'msg_test'
    )

    text = body[:content].find { |block| block[:type] == 'text' }[:text]
    expect(text).to eq('visible answer')
    expect(Legion::JSON.dump(body)).not_to include('Legion::Extensions::Llm::Canonical::ContentBlock')
  end

  it 'does not leak Ruby canonical object inspect strings through OpenAI Chat responses' do
    body = Legion::LLM::API::ClientTranslators::OpenAIChat.new.format_response(
      pipeline_response,
      model:      'fake-default',
      request_id: 'chat_test'
    )

    text = body[:choices].first[:message][:content]
    expect(text).to eq('visible answer')
    expect(Legion::JSON.dump(body)).not_to include('Legion::Extensions::Llm::Canonical::ContentBlock')
  end
end
