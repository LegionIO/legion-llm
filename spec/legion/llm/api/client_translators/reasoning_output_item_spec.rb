# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/openai_responses'

# Regression for the hello_ping_reasoning e2e cells (codex -> vllm / bedrock).
#
# The provider returns thinking; the executor surfaces it on
# pipeline_response.thinking. OpenAIResponses#build_output_reasoning rendered
# it as an output item of `type: "thinking"` with a `thinking:` field — but the
# Responses-API reasoning surface that the Codex client (and the legionio-e2e
# CodexValidate.validate_responses_reasoning gate) consumes is a `message`
# output item with `phase: "reasoning"` whose content carries `output_text`
# blocks, OR a usage breakdown with output_tokens_details.reasoning_tokens.
#
# The `type: "thinking"` shape satisfied neither, so reasoning silently
# vanished from the client's perspective even though the provider produced it.
RSpec.describe Legion::LLM::API::ClientTranslators::OpenAIResponses do
  let(:translator) { described_class.new }

  # Minimal pipeline-response stand-in carrying thinking text the way the
  # executor's Inference::Response envelope exposes it.
  fake_response_class = Struct.new(:thinking, :routing, :tokens, :message, :tools, :stop, keyword_init: true)

  let(:pipeline_response) do
    fake_response_class.new(
      thinking: { content: 'Let me work through 2 + 2 step by step.' },
      routing:  { model: 'qwen3.6-27b' },
      tokens:   { input_tokens: 10, output_tokens: 20 },
      message:  { content: '2 + 2 = 4.' },
      tools:    nil,
      stop:     nil
    )
  end

  describe '#format_response reasoning output item' do
    subject(:output) do
      translator.format_response(pipeline_response, model: 'qwen3.6-27b', request_id: 'resp_test')[:output]
    end

    let(:reasoning_item) do
      output.find { |o| o[:type] == 'message' && o[:phase] == 'reasoning' }
    end

    it 'emits a message output item with phase: reasoning (not type: thinking)' do
      expect(output.any? { |o| o[:type] == 'thinking' }).to be(false)
      expect(reasoning_item).not_to be_nil
    end

    it 'carries the reasoning text in an output_text content block' do
      texts = reasoning_item[:content].select { |c| c[:type] == 'output_text' }
      expect(texts).not_to be_empty
      expect(texts.sum { |c| c[:text].length }).to be > 0
      expect(texts.first[:text]).to include('2 + 2')
    end

    it 'still emits the assistant answer as a separate completed message item' do
      answer = output.select { |o| o[:type] == 'message' && o[:phase] != 'reasoning' }
      expect(answer.size).to eq(1)
      expect(answer.first[:content].first[:text]).to include('2 + 2 = 4.')
    end

    it 'omits the reasoning item entirely when there is no thinking' do
      no_thinking = pipeline_response.dup.tap { |r| r.thinking = nil }
      out = translator.format_response(no_thinking, model: 'qwen3.6-27b', request_id: 'resp_test')[:output]
      expect(out.none? { |o| o[:phase] == 'reasoning' }).to be(true)
    end
  end
end
