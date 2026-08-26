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
      expect(req).to be_a(canonical::Request)
      expect(req.thinking).to be_a(canonical::Thinking::Config)
      expect(req.thinking.budget).to eq(1024)
    end

    # M4: effort is a closed enum (EFFORT_BUDGET keys), so the bare-flag edge
    # may only map values that are themselves valid efforts — never fabricate.
    it 'drops a bare true thinking flag (the dialect documents no default effort)' do
      body = {
        model:      'claude-haiku-4-5-20251001',
        messages:   [{ role: 'user', content: 'hi' }],
        max_tokens: 1024,
        thinking:   true
      }
      expect { translator.parse_request(body, {}) }.not_to raise_error
      expect(translator.parse_request(body, {}).thinking).to be_nil
    end

    it 'drops a bare "enabled" thinking flag' do
      body = {
        model:      'claude-haiku-4-5-20251001',
        messages:   [{ role: 'user', content: 'hi' }],
        max_tokens: 1024,
        thinking:   'enabled'
      }
      expect { translator.parse_request(body, {}) }.not_to raise_error
      expect(translator.parse_request(body, {}).thinking).to be_nil
    end

    it 'drops a bare false thinking flag' do
      body = {
        model:      'claude-haiku-4-5-20251001',
        messages:   [{ role: 'user', content: 'hi' }],
        max_tokens: 1024,
        thinking:   false
      }
      req = translator.parse_request(body, {})
      expect(req.thinking).to be_nil
    end

    it 'honors a bare closed-enum effort string 1:1' do
      body = {
        model:      'claude-haiku-4-5-20251001',
        messages:   [{ role: 'user', content: 'hi' }],
        max_tokens: 1024,
        thinking:   'high'
      }
      req = translator.parse_request(body, {})
      expect(req.thinking).to be_a(canonical::Thinking::Config)
      expect(req.thinking.effort).to eq('high')
      expect(req.thinking.budget).to be_nil
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

    # /v1/responses supplies ONLY the effort axis. The translator emits
    # effort-only; the budget is NOT fabricated here — it is derived at the
    # provider edge via Thinking::Config#resolved_budget (EFFORT_BUDGET).
    it 'parses a Responses API reasoning effort without raising' do
      body = { model: 'gpt-5.4', input: 'hi', reasoning: { effort: 'medium' } }
      expect { translator.parse_request(body, {}) }.not_to raise_error
      req = translator.parse_request(body, {})
      expect(req.thinking).to be_a(canonical::Thinking::Config)
      expect(req.thinking.effort).to eq('medium')
      expect(req.thinking.budget).to be_nil
      # The provider edge resolves the SSOT budget from effort on demand.
      expect(req.thinking.resolved_budget).to eq(8192)
    end

    it "handles 'low' effort" do
      body = { model: 'gpt-5.4', input: 'hi', reasoning: { effort: 'low' } }
      req = translator.parse_request(body, {})
      expect(req.thinking.effort).to eq('low')
      expect(req.thinking.budget).to be_nil
    end

    it 'drops an unrecognized effort rather than forwarding an arbitrary string' do
      body = { model: 'gpt-5.4', input: 'hi', reasoning: { effort: 'turbo' } }
      req = translator.parse_request(body, {})
      expect(req.thinking).to be_nil
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
      # N2: shared execution carries the canonical Thinking::Config, not a
      # client-dialect {type:, budget_tokens:} shape. Effort-only — the budget
      # is resolved at the provider edge (resolved_budget), never fabricated by
      # the /v1/responses translator.
      expect(inference_request.thinking).to be_a(canonical::Thinking::Config)
      expect(inference_request.thinking.effort).to eq('high')
      expect(inference_request.thinking.budget).to be_nil
      expect(inference_request.thinking.resolved_budget).to eq(16_384)
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
