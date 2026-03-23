# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/hooks'
require 'legion/llm/hooks/cost_tracking'
require 'legion/llm/cost_tracker'

RSpec.describe Legion::LLM::Hooks::CostTracking do
  after do
    Legion::LLM::Hooks.reset!
    Legion::LLM::CostTracker.clear
  end

  describe '.install' do
    it 'registers an after_chat hook' do
      expect { described_class.install }.to change {
        Legion::LLM::Hooks.instance_variable_get(:@after_chat).size
      }.by(1)
    end
  end

  describe '.track' do
    it 'records cost via CostTracker' do
      response = {
        usage: { input_tokens: 500, output_tokens: 200 },
        meta:  { provider: 'anthropic', model: 'claude-sonnet-4-6' }
      }

      described_class.track(response, 'claude-sonnet-4-6')
      summary = Legion::LLM::CostTracker.summary
      expect(summary[:total_requests]).to eq(1)
      expect(summary[:total_input_tokens]).to eq(500)
      expect(summary[:total_output_tokens]).to eq(200)
    end

    it 'skips zero-token responses' do
      response = { usage: { input_tokens: 0, output_tokens: 0 } }

      described_class.track(response, 'gpt-4o')
      summary = Legion::LLM::CostTracker.summary
      expect(summary[:total_requests]).to eq(0)
    end

    it 'handles non-hash responses gracefully' do
      described_class.track('raw string', 'gpt-4o')
      summary = Legion::LLM::CostTracker.summary
      expect(summary[:total_requests]).to eq(0)
    end

    it 'uses prompt_tokens and completion_tokens as fallbacks' do
      response = { usage: { prompt_tokens: 100, completion_tokens: 50 } }

      described_class.track(response, 'gpt-4o')
      summary = Legion::LLM::CostTracker.summary
      expect(summary[:total_input_tokens]).to eq(100)
      expect(summary[:total_output_tokens]).to eq(50)
    end

    it 'uses model from response meta when available' do
      response = {
        usage: { input_tokens: 100, output_tokens: 50 },
        meta:  { model: 'gpt-4o-mini' }
      }

      described_class.track(response, 'gpt-4o')
      summary = Legion::LLM::CostTracker.summary
      expect(summary[:by_model]).to have_key('gpt-4o-mini')
    end

    it 'falls back to passed model when response has no model' do
      response = { usage: { input_tokens: 100, output_tokens: 50 } }

      described_class.track(response, 'claude-haiku-4-5')
      summary = Legion::LLM::CostTracker.summary
      expect(summary[:by_model]).to have_key('claude-haiku-4-5')
    end
  end

  describe '.extract_usage' do
    it 'returns zeros for non-hash' do
      result = described_class.extract_usage('string')
      expect(result).to eq({ input_tokens: 0, output_tokens: 0 })
    end

    it 'extracts standard usage keys' do
      result = described_class.extract_usage({ usage: { input_tokens: 10, output_tokens: 20 } })
      expect(result[:input_tokens]).to eq(10)
      expect(result[:output_tokens]).to eq(20)
    end
  end
end
