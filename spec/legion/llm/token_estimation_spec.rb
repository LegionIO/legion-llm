# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/token_estimation'

RSpec.describe Legion::LLM::TokenEstimation do
  describe '.estimate' do
    it 'estimates token count from messages' do
      result = described_class.estimate(
        messages: [{ role: :user, content: 'Hello, how are you doing today?' }],
        model:    'claude-sonnet-4-6'
      )

      expect(result[:input_tokens]).to be_a(Integer)
      expect(result[:input_tokens]).to be > 0
    end

    it 'includes system prompt in count' do
      without_system = described_class.estimate(
        messages: [{ role: :user, content: 'Hello' }],
        model:    'claude-sonnet-4-6'
      )

      with_system = described_class.estimate(
        messages: [{ role: :user, content: 'Hello' }],
        model:    'claude-sonnet-4-6',
        system:   'You are a helpful assistant with deep expertise in distributed systems and Ruby.'
      )

      expect(with_system[:input_tokens]).to be > without_system[:input_tokens]
    end

    it 'includes tool definitions in count' do
      without_tools = described_class.estimate(
        messages: [{ role: :user, content: 'Hello' }],
        model:    'claude-sonnet-4-6'
      )

      with_tools = described_class.estimate(
        messages: [{ role: :user, content: 'Hello' }],
        model:    'claude-sonnet-4-6',
        tools:    [{ name: 'get_weather', description: 'Get weather for a location',
input_schema: { type: 'object', properties: { city: { type: 'string' } }, required: ['city'] } }]
      )

      expect(with_tools[:input_tokens]).to be > without_tools[:input_tokens]
    end

    it 'handles array content blocks' do
      result = described_class.estimate(
        messages: [{ role: :user, content: [{ type: 'text', text: 'Hello world this is a test message' }] }],
        model:    'claude-sonnet-4-6'
      )

      expect(result[:input_tokens]).to be > 0
    end

    it 'handles empty messages' do
      result = described_class.estimate(messages: [], model: 'claude-sonnet-4-6')
      expect(result[:input_tokens]).to eq(0)
    end

    it 'handles nil system and tools' do
      result = described_class.estimate(
        messages: [{ role: :user, content: 'Hi' }],
        model:    'test',
        system:   nil,
        tools:    nil
      )
      expect(result[:input_tokens]).to be > 0
    end
  end
end
