# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM::Settings api.use_namespaces toggle' do
  describe 'default settings' do
    it 'defaults use_namespaces to true' do
      defaults = Legion::LLM::Settings.default
      expect(defaults[:api][:use_namespaces]).to eq(true)
    end

    it 'is accessible via Legion::Settings[:llm]' do
      result = Legion::Settings[:llm][:api][:use_namespaces]
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
      Legion::LLM::Settings.register_defaults!
    end

    it 'returns nil when setting is absent from runtime hash' do
      Legion::Settings[:llm][:api].delete(:use_namespaces)
      result = Legion::Settings[:llm][:api][:use_namespaces]
      expect(result).to be_nil
    end

    it 'returns true when explicitly set to true' do
      Legion::Settings[:llm][:api][:use_namespaces] = true
      result = Legion::Settings[:llm][:api][:use_namespaces]
      expect(result).to eq(true)
    end
  end
end
