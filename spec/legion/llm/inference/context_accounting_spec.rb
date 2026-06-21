# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::ContextAccounting do
  describe '.estimate_text_tokens' do
    it 'estimates tokens using char/4 ceiling' do
      expect(described_class.estimate_text_tokens('abcd' * 10)).to eq(10)
    end

    it 'returns 1 for very short strings' do
      expect(described_class.estimate_text_tokens('hi')).to eq(1)
    end

    it 'handles nil input' do
      expect(described_class.estimate_text_tokens(nil)).to eq(0)
    end
  end

  describe '.estimate_message_tokens' do
    it 'estimates tokens from chat messages' do
      messages = [
        { role: 'user', content: 'hello world' },
        { role: 'assistant', content: [{ type: 'text', text: 'answer text' }] }
      ]
      expect(described_class.estimate_message_tokens(messages)).to be > 0
    end

    it 'handles empty messages' do
      expect(described_class.estimate_message_tokens([])).to eq(0)
    end
  end

  describe '.estimate_json_tokens' do
    it 'estimates tokens from serialized JSON' do
      value = { name: 'test_tool', description: 'A tool' }
      expect(described_class.estimate_json_tokens(value)).to be > 0
    end
  end

  describe '.empty' do
    it 'builds an empty accounting payload with schema and estimator metadata' do
      payload = described_class.empty

      expect(payload[:schema_version]).to eq(1)
      expect(payload[:status]).to eq(:estimated)
      expect(payload.dig(:estimator, :name)).to eq(:legion_char_div_four)
      expect(payload[:tokens]).to include(:final_context_estimated_tokens)
      expect(payload[:counts]).to include(:rag_entry_count)
      expect(payload[:events]).to eq([])
      expect(payload[:component_status]).to include(:context_load, :rag, :tools, :system)
    end

    it 'accepts custom status' do
      payload = described_class.empty(status: :profile_skipped)
      expect(payload[:status]).to eq(:profile_skipped)
    end
  end

  describe '.event' do
    it 'builds a structured event hash' do
      ev = described_class.event(
        event_type:    :context_load,
        component:     :conversation_history,
        before_tokens: 0,
        after_tokens:  500,
        before_count:  0,
        after_count:   5
      )

      expect(ev[:event_type]).to eq(:context_load)
      expect(ev[:component]).to eq(:conversation_history)
      expect(ev[:estimated_tokens_before]).to eq(0)
      expect(ev[:estimated_tokens_after]).to eq(500)
      expect(ev[:estimated_tokens_delta]).to eq(500)
      expect(ev[:message_count_before]).to eq(0)
      expect(ev[:message_count_after]).to eq(5)
    end
  end

  describe '.message_text' do
    it 'extracts string content from a message hash' do
      expect(described_class.message_text({ content: 'hello' })).to eq('hello')
    end

    it 'extracts text from array content blocks' do
      msg = { content: [{ type: 'text', text: 'first' }, { type: 'text', text: 'second' }] }
      expect(described_class.message_text(msg)).to eq("first\nsecond")
    end

    it 'handles non-hash input' do
      expect(described_class.message_text('raw string')).to eq('raw string')
    end
  end

  # Regression: Canonical::Message is a Data struct — its #to_s returns
  # #inspect (timestamps, nested ContentBlocks, tool_calls). Estimating
  # tokens from #to_s produced ~854K "tokens" for hello_ping and broke
  # Router.request_lane's context-window filter (every lane rejected).
  describe '.estimate_message_tokens (Canonical regression)' do
    it 'returns < 50 tokens for a hello-world Canonical::Message' do
      msg = Legion::Extensions::Llm::Canonical::Message.build(
        role: :user, content: 'Say hello in exactly 3 words.'
      )
      expect(described_class.estimate_message_tokens(msg)).to be < 50
    end

    it 'sums multiple text ContentBlocks correctly' do
      msg = Legion::Extensions::Llm::Canonical::Message.build(
        role:    :user,
        content: [
          Legion::Extensions::Llm::Canonical::ContentBlock.text('hi'),
          Legion::Extensions::Llm::Canonical::ContentBlock.text('there')
        ]
      )
      # "hithere" = 7 chars / 4 = 2 tokens (ceil)
      expect(described_class.estimate_message_tokens(msg)).to be <= 5
    end

    it 'handles legacy Hash messages (back-compat path)' do
      msg = { role: :user, content: [{ type: 'text', text: 'hello' }] }
      expect(described_class.estimate_message_tokens(msg)).to be <= 3
    end

    it 'returns 0 for a Canonical::Message with only tool_calls (no text content)' do
      msg = Legion::Extensions::Llm::Canonical::Message.build(
        role: :assistant, content: nil,
        tool_calls: [Legion::Extensions::Llm::Canonical::ToolCall.from_hash(
          id: '1', name: 'foo', arguments: { x: 1 }
        )]
      )
      expect(described_class.estimate_message_tokens(msg)).to eq(0)
    end
  end
end
