# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/translators/anthropic_request'

RSpec.describe Legion::LLM::API::Translators::AnthropicRequest do
  describe '.normalize' do
    it 'joins string text blocks into a single user message' do
      normalized = described_class.normalize(
        messages: [{ role: 'user', content: [{ type: 'text', text: 'hello' }, { type: 'text', text: ' world' }] }],
        model:    'claude-sonnet-4-6'
      )

      expect(normalized[:messages].first[:content]).to eq('hello world')
      expect(normalized[:messages].first[:role]).to eq(:user)
    end

    it 'splits tool_result into a separate tool role message' do
      normalized = described_class.normalize(
        messages: [
          {
            role:    'user',
            content: [
              { type: 'text', text: 'result:' },
              { type: 'tool_result', tool_use_id: 'toolu_1', content: 'done' }
            ]
          }
        ],
        model:    'claude-sonnet-4-6'
      )

      expect(normalized[:messages].size).to eq(2)
      expect(normalized[:messages][0]).to eq({ role: :user, content: 'result:' })
      expect(normalized[:messages][1]).to eq({ role: :tool, tool_call_id: 'toolu_1', content: 'done' })
    end

    it 'extracts tool_use from assistant content into tool_calls' do
      normalized = described_class.normalize(
        messages: [
          {
            role:    'assistant',
            content: [
              { type: 'text', text: 'Reading file' },
              { type: 'tool_use', id: 'call_123', name: 'Read', input: { file_path: '/tmp/x' } }
            ]
          }
        ],
        model:    'claude-sonnet-4-6'
      )

      msg = normalized[:messages].first
      expect(msg[:role]).to eq(:assistant)
      expect(msg[:content]).to eq('Reading file')
      expect(msg[:tool_calls]).to eq([{ id: 'call_123', name: 'Read', arguments: { file_path: '/tmp/x' } }])
    end
  end
end
