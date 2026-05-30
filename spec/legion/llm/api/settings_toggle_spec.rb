# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM::Settings api.use_namespaces toggle' do
  describe 'default settings' do
    it 'defaults use_namespaces to true' do
      defaults = Legion::LLM::Settings.default
      expect(defaults[:api][:use_namespaces]).to eq(true)
    end

    it 'is accessible via Settings.value' do
      result = Legion::LLM::Settings.value(:api, :use_namespaces)
      expect(result).to eq(true)
    end

    it 'does not break existing api.auth defaults' do
      defaults = Legion::LLM::Settings.default
      expect(defaults[:api][:auth][:enabled]).to eq(false)
      expect(defaults[:api][:auth][:api_keys]).to eq([])
    end
  end

  describe 'settings toggle behavior' do
    after do
      # Reset to registered defaults to prevent cross-test bleed
      Legion::LLM::Settings.register_defaults!
    end

    it 'returns false when setting is absent from runtime hash' do
      # Simulate settings hash without use_namespaces key
      allow(Legion::Settings).to receive(:[]).with(:llm).and_return({ api: { auth: { enabled: false } } })
      result = Legion::LLM::Settings.value(:api, :use_namespaces, default: false)
      expect(result).to eq(false)
    end

    it 'returns true when explicitly set to true' do
      allow(Legion::Settings).to receive(:[]).with(:llm).and_return({ api: { use_namespaces: true, auth: { enabled: false } } })
      result = Legion::LLM::Settings.value(:api, :use_namespaces, default: false)
      expect(result).to eq(true)
    end
  end
end
