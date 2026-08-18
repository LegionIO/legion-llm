# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm'

RSpec.describe 'Legion::LLM enterprise privacy mode' do
  before do
    allow(Legion::Settings).to receive(:enterprise_privacy?).and_return(true)
    allow(Legion::Settings).to receive(:[]).and_call_original
    defaults = Legion::LLM::Settings.default
    defaults[:routing][:escalation][:enabled] = false
    allow(Legion::Settings).to receive(:[]).with(:llm).and_return(defaults)
    allow(Legion::Settings).to receive(:[]).with(:transport).and_return({ connected: false })
    allow(Legion::Settings).to receive(:[]).with(:extensions).and_return({})
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

  describe '.chat_direct with tier: :frontier' do
    it 'raises PrivacyModeError when enterprise privacy is enabled' do
      expect do
        Legion::LLM.chat_direct(tier: :frontier, message: 'hello')
      end.to raise_error(Legion::LLM::PrivacyModeError)
    end
  end

  describe '.chat_direct with tier: :local' do
    it 'does not raise PrivacyModeError for local tier' do
      # SSOT v3: publish via Phase-1 Registry so RoutingSession can select the lane.
      write_test_lane(provider: :ollama, model: 'llama3', tier: :local)
      expect do
        Legion::LLM.chat_direct(tier: :local, provider: :ollama, model: 'llama3', message: 'hello')
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
      allow(Legion::Settings).to receive(:[]).with(:transport).and_return({ connected: false })
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

    it 'returns true for :local when enterprise privacy is enabled' do
      expect(Legion::LLM::Router.tier_available?(:local)).to be true
    end
  end
end
