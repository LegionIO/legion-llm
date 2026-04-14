# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Executor do
  describe '#ruby_llm_chat_options' do
    context 'when @request.thinking is nil' do
      let(:request) do
        Legion::LLM::Pipeline::Request.build(
          messages: [{ role: :user, content: 'hello' }],
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
        )
      end

      it 'does not include thinking key in options' do
        executor = described_class.new(request)
        executor.instance_variable_set(:@resolved_provider, :anthropic)
        executor.instance_variable_set(:@resolved_model, 'claude-opus-4-6')
        opts = executor.send(:ruby_llm_chat_options)
        expect(opts).not_to have_key(:thinking)
      end
    end

    context 'when @request.thinking is set' do
      let(:thinking_config) { { type: :enabled, budget_tokens: 5000 } }

      let(:request) do
        Legion::LLM::Pipeline::Request.build(
          messages: [{ role: :user, content: 'reason through this' }],
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
          thinking: thinking_config
        )
      end

      it 'includes thinking in the chat options' do
        executor = described_class.new(request)
        executor.instance_variable_set(:@resolved_provider, :anthropic)
        executor.instance_variable_set(:@resolved_model, 'claude-opus-4-6')
        opts = executor.send(:ruby_llm_chat_options)
        expect(opts[:thinking]).to eq(thinking_config)
      end
    end
  end
end
