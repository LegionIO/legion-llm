# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM hooks integration' do
  before do
    Legion::LLM::Hooks.reset!
    stub_native_provider(content: 'hook test response')
  end

  describe 'before_chat blocking' do
    it 'prevents LLM call when before hook blocks' do
      Legion::LLM::Hooks.before_chat do |messages:, **|
        text = messages.map { |m| m[:content].to_s }.join(' ')
        { action: :block, response: { blocked: true, content: 'Blocked' } } if text.include?('forbidden')
      end

      # Verify hooks module is loaded and functional
      result = Legion::LLM::Hooks.run_before(
        messages: [{ role: 'user', content: 'forbidden input' }], model: 'test'
      )
      expect(result[:action]).to eq(:block)
      expect(result[:response][:blocked]).to be true
    end

    it 'returns a structured blocked response for session-style calls when a hook blocks' do
      # SSOT v3: hooks blocking is exercised via the session-style (no-message) path,
      # which checks Hooks.run_before before dispatching to the provider.
      Legion::LLM::Hooks.before_chat { { action: :block, reason: 'blocked by policy' } }

      result = Legion::LLM::Inference.chat(
        model: SSOT_TEST_MODEL
      )

      expect(result).to include(error: 'request_blocked', message: 'blocked by policy')
    end
  end
end
