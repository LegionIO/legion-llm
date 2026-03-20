# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Hooks do
  before { described_class.reset! }

  describe '.before_chat' do
    it 'registers a before hook' do
      described_class.before_chat { |**_| nil }
      expect(described_class.instance_variable_get(:@before_chat).size).to eq(1)
    end
  end

  describe '.after_chat' do
    it 'registers an after hook' do
      described_class.after_chat { |**_| nil }
      expect(described_class.instance_variable_get(:@after_chat).size).to eq(1)
    end
  end

  describe '.run_before' do
    it 'returns nil when no hooks block' do
      described_class.before_chat { |**_| nil }
      result = described_class.run_before(messages: [{ role: 'user', content: 'hello' }], model: 'test')
      expect(result).to be_nil
    end

    it 'returns block result when a hook returns action: :block' do
      described_class.before_chat do |messages:, **|
        { action: :block, response: { success: false, blocked: true } } if messages.any? { |m| m[:content].include?('bad') }
      end
      result = described_class.run_before(messages: [{ role: 'user', content: 'bad input' }], model: 'test')
      expect(result[:action]).to eq(:block)
    end

    it 'passes through when no hook blocks' do
      described_class.before_chat { |**_| nil }
      result = described_class.run_before(messages: [{ role: 'user', content: 'good' }], model: 'test')
      expect(result).to be_nil
    end
  end

  describe '.run_after' do
    it 'returns nil when no hooks block' do
      described_class.after_chat { |**_| nil }
      result = described_class.run_after(response: { content: 'ok' },
                                         messages: [{ role: 'user', content: 'hi' }], model: 'test')
      expect(result).to be_nil
    end

    it 'blocks when a hook returns action: :block' do
      described_class.after_chat do |response:, **|
        content = response.is_a?(Hash) ? response[:content].to_s : response.to_s
        { action: :block, response: { blocked: true } } if content.include?('secret')
      end
      result = described_class.run_after(response: { content: 'the secret is 42' },
                                         messages: [], model: 'test')
      expect(result[:action]).to eq(:block)
    end
  end

  describe '.reset!' do
    it 'clears all hooks' do
      described_class.before_chat { nil }
      described_class.after_chat { nil }
      described_class.reset!
      expect(described_class.instance_variable_get(:@before_chat)).to eq([])
      expect(described_class.instance_variable_get(:@after_chat)).to eq([])
    end
  end
end
