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
  end

  describe Legion::LLM::API::ClientTranslators::OpenAIChat do
    let(:translator) { described_class.new }

    it 'parses without raising even when no thinking config is provided' do
      body = { model: 'qwen3.6-27b', messages: [{ role: 'user', content: 'hi' }] }
      expect { translator.parse_request(body, {}) }.not_to raise_error
    end
  end
end
