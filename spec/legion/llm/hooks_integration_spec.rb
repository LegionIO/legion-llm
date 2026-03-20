# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM hooks integration' do
  before { Legion::LLM::Hooks.reset! }

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
  end
end
