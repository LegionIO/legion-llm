# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm'

RSpec.describe 'Legion::LLM enterprise privacy mode' do
  before do
    allow(Legion::Settings).to receive(:enterprise_privacy?).and_return(true)
    allow(Legion::Settings).to receive(:[]).with(:llm).and_return(
      Legion::LLM::Settings.default
    )
  end

  describe 'Legion::LLM::PrivacyModeError' do
    it 'is defined' do
      expect(defined?(Legion::LLM::PrivacyModeError)).to be_truthy
    end
  end

  describe '.chat_direct with tier: :cloud' do
    it 'raises PrivacyModeError when enterprise privacy is enabled' do
      expect do
        Legion::LLM.chat_direct(tier: :cloud, message: 'hello')
      end.to raise_error(Legion::LLM::PrivacyModeError, /enterprise_data_privacy/)
    end
  end

  describe '.chat_direct with tier: :local' do
    it 'does not raise PrivacyModeError for local tier' do
      session_double = double('session', ask: double('response', content: 'pong'))
      allow(RubyLLM).to receive(:chat).and_return(session_double)
      expect do
        Legion::LLM.chat_direct(tier: :local, message: 'hello')
      end.not_to raise_error
    end
  end

  describe '.ask_direct with cloud provider' do
    it 'raises PrivacyModeError when provider is a cloud provider' do
      allow(Legion::Settings).to receive(:[]).with(:llm).and_return(
        Legion::LLM::Settings.default.merge(
          default_provider: :anthropic,
          default_model:    'claude-sonnet-4-6'
        )
      )
      expect do
        Legion::LLM::Inference.send(:ask_direct, message: 'hello')
      end.to raise_error(Legion::LLM::PrivacyModeError)
    end
  end

  describe 'Router.tier_available? with privacy enforcement' do
    it 'returns false for :cloud when enterprise privacy is enabled' do
      expect(Legion::LLM::Router.tier_available?(:cloud)).to be false
    end

    it 'returns false for :frontier when enterprise privacy is enabled' do
      expect(Legion::LLM::Router.tier_available?(:frontier)).to be false
    end

    it 'returns false for :openai_compat when enterprise privacy is enabled' do
      expect(Legion::LLM::Router.tier_available?(:openai_compat)).to be false
    end

    it 'returns true for :local when enterprise privacy is enabled' do
      expect(Legion::LLM::Router.tier_available?(:local)).to be true
    end
  end
end
