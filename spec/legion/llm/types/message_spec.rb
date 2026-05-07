# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/types/message'

RSpec.describe Legion::LLM::Types::Message do
  describe '#text' do
    it 'extracts text blocks with string keys' do
      message = described_class.build(
        content: [{ 'type' => 'text', 'text' => 'hello' }, { 'type' => 'image', 'url' => 'https://example.test/image.png' }]
      )

      expect(message.text).to eq('hello')
    end
  end

  describe '#full_content' do
    it 'preserves non-text content as JSON for audit and persistence callers' do
      content = [{ 'type' => 'image', 'url' => 'https://example.test/image.png' }]
      message = described_class.build(content: content)

      expect(message.full_content).to include('"type":"image"')
      expect(message.full_content).to include('"url":"https://example.test/image.png"')
    end
  end
end
