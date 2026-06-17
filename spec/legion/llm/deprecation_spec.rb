# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/deprecation'

RSpec.describe Legion::LLM::Deprecation do
  before(:each) do
    described_class.reset!
  end

  describe '.warn_once' do
    let(:logger) { instance_double('Logger', warn: nil) }

    before { allow(described_class).to receive(:log).and_return(logger) }

    it 'emits a log.warn on first call' do
      described_class.warn_once(:chat_direct, replacement: 'Legion::LLM.chat')
      expect(logger).to have_received(:warn).once
    end

    it 'does not emit on second call for same method' do
      described_class.warn_once(:chat_direct, replacement: 'Legion::LLM.chat')
      described_class.warn_once(:chat_direct, replacement: 'Legion::LLM.chat')
      expect(logger).to have_received(:warn).once
    end

    it 'emits for different methods independently' do
      described_class.warn_once(:chat_direct, replacement: 'Legion::LLM.chat')
      described_class.warn_once(:embed_direct, replacement: 'Legion::LLM.embed')
      expect(logger).to have_received(:warn).twice
    end

    it 'includes the method name and replacement in the message' do
      described_class.warn_once(:chat_direct, replacement: 'Legion::LLM.chat')
      expect(logger).to have_received(:warn).with(a_string_matching(/chat_direct.*Legion::LLM\.chat/))
    end
  end

  describe '.warned?' do
    it 'returns false before any warning' do
      expect(described_class.warned?(:chat_direct)).to be false
    end

    it 'returns true after a warning' do
      allow(described_class).to receive(:log).and_return(instance_double('Logger', warn: nil))
      described_class.warn_once(:chat_direct, replacement: 'Legion::LLM.chat')
      expect(described_class.warned?(:chat_direct)).to be true
    end
  end

  describe '.reset!' do
    it 'clears all warned state' do
      allow(described_class).to receive(:log).and_return(instance_double('Logger', warn: nil))
      described_class.warn_once(:chat_direct, replacement: 'Legion::LLM.chat')
      described_class.reset!
      expect(described_class.warned?(:chat_direct)).to be false
    end
  end
end
