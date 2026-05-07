# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/translators/anthropic_request'

RSpec.describe Legion::LLM::API::Translators::AnthropicRequest do
  describe '.normalize' do
    it 'joins string text blocks without raising' do
      normalized = described_class.normalize(
        messages: [{ role: 'user', content: [{ type: 'text', text: 'hello' }, { type: 'text', text: ' world' }] }],
        model:    'claude-sonnet-4-6'
      )

      expect(normalized[:messages].first[:content]).to eq('hello world')
    end

    it 'preserves structured Anthropic content blocks' do
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

      expect(normalized[:messages].first[:content]).to eq(
        ['result:', { type: :tool_result, tool_use_id: 'toolu_1', content: 'done' }]
      )
    end
  end
end
