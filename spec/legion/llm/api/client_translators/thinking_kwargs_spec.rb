# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/api/client_translators/openai_chat'

# Regression: client_translators were passing {enabled:, type:, budget_tokens:}
# into Canonical::Request.build, which forwards to Thinking::Config.new — and
# that constructor only accepts {effort:, budget:}. Result: ArgumentError on
# every request that carried thinking/reasoning config.
RSpec.describe 'Client translator thinking/reasoning kwargs' do
  let(:canonical) { Legion::Extensions::Llm::Canonical }

  describe Legion::LLM::API::ClientTranslators::AnthropicMessages do
    let(:translator) { described_class.new }

    it 'parses an Anthropic thinking config without raising' do
      body = {
        model:      'claude-haiku-4-5-20251001',
        messages:   [{ role: 'user', content: 'hi' }],
        max_tokens: 1024,
        thinking:   { type: 'enabled', budget_tokens: 1024 }
      }
      expect { translator.parse_request(body, {}) }.not_to raise_error
      req = translator.parse_request(body, {})
      expect(req).to be_a(canonical::Request)
      expect(req.thinking).to be_a(canonical::ThinkingConfig)
      expect(req.thinking.budget).to eq(1024)
    end

    it 'forwards max_tokens and stop sequences into the inference request' do
      body = {
        model:          'claude-haiku-4-5-20251001',
        messages:       [{ role: 'user', content: 'hi' }],
        max_tokens:     77,
        stop_sequences: ['done'],
        temperature:    0.2
      }
      canonical_request = translator.parse_request(body, {})
      inference_request = translator.build_inference_request(
        canonical_request,
        request_id:    'req_anthropic',
        server_caller: { source: 'spec' }
      )

      expect(inference_request.tokens).to eq(max: 77)
      expect(inference_request.stop).to eq(sequences: ['done'])
      expect(inference_request.generation).to include(temperature: 0.2)
    end
  end

  describe Legion::LLM::API::ClientTranslators::OpenAIResponses do
    let(:translator) { described_class.new }

    it 'parses a Responses API reasoning effort without raising' do
      body = { model: 'gpt-5.4', input: 'hi', reasoning: { effort: 'medium' } }
      expect { translator.parse_request(body, {}) }.not_to raise_error
      req = translator.parse_request(body, {})
      expect(req.thinking).to be_a(canonical::ThinkingConfig)
      expect(req.thinking.effort).to eq('medium')
      expect(req.thinking.budget).to eq(1024)
    end

    it "handles 'low' effort" do
      body = { model: 'gpt-5.4', input: 'hi', reasoning: { effort: 'low' } }
      req = translator.parse_request(body, {})
      expect(req.thinking.budget).to eq(512)
    end

    it 'returns nil thinking when reasoning is absent' do
      req = translator.parse_request({ model: 'gpt-5.4', input: 'hi' }, {})
      expect(req.thinking).to be_nil
    end

    it 'forwards max_output_tokens and reasoning into the inference request' do
      body = {
        model:             'gpt-5.4',
        input:             'hi',
        max_output_tokens: 50,
        temperature:       0.1,
        reasoning:         { effort: 'high' }
      }
      canonical_request = translator.parse_request(body, {})
      inference_request = translator.build_inference_request(
        canonical_request,
        request_id:    'req_responses',
        server_caller: { source: 'spec' }
      )

      expect(inference_request.tokens).to eq(max: 50)
      expect(inference_request.generation).to include(temperature: 0.1)
      expect(inference_request.thinking).to include(type: 'enabled', effort: 'high', budget_tokens: 1024)
    end
  end

  describe Legion::LLM::API::ClientTranslators::OpenAIChat do
    let(:translator) { described_class.new }

    it 'parses without raising even when no thinking config is provided' do
      body = { model: 'qwen3.6-27b', messages: [{ role: 'user', content: 'hi' }] }
      expect { translator.parse_request(body, {}) }.not_to raise_error
    end

    it 'forwards max_tokens, response_format, and stop sequences into the inference request' do
      body = {
        model:           'qwen3.6-27b',
        messages:        [{ role: 'user', content: 'hi' }],
        max_tokens:      64,
        response_format: { type: 'json_object' },
        stop:            ['END'],
        temperature:     0.3
      }
      canonical_request = translator.parse_request(body, {})
      inference_request = translator.build_inference_request(
        canonical_request,
        request_id:    'req_chat',
        server_caller: { source: 'spec' }
      )

      expect(inference_request.tokens).to eq(max: 64)
      expect(inference_request.response_format).to eq(type: 'json_object')
      expect(inference_request.stop).to eq(sequences: ['END'])
      expect(inference_request.generation).to include(temperature: 0.3)
    end
  end
end
