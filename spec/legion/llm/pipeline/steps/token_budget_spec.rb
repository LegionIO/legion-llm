# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::TokenBudget do
  let(:executor_class) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::TokenBudget

      attr_accessor :warnings

      def initialize(request)
        @request  = request
        @warnings = []
      end
    end
  end

  def build_executor(messages: [{ role: :user, content: 'hello world' }], system: nil, extra: {})
    request = Legion::LLM::Pipeline::Request.build(
      messages: messages,
      system:   system,
      extra:    extra
    )
    executor_class.new(request)
  end

  before(:each) do
    Legion::LLM::TokenTracker.reset!
    Legion::Settings[:llm][:budget] = Legion::LLM::Settings.budget_defaults
  end

  describe '#step_token_budget' do
    context 'when no limits are configured' do
      it 'passes through without raising' do
        ex = build_executor
        expect { ex.step_token_budget }.not_to raise_error
        expect(ex.warnings).to be_empty
      end
    end

    context 'when max_input_tokens is set in request.extra' do
      it 'passes when estimated input is within the cap' do
        # "hello world" = 11 chars => ~2 estimated tokens (chars / 4)
        ex = build_executor(
          messages: [{ role: :user, content: 'hello world' }],
          extra:    { max_input_tokens: 100 }
        )
        expect { ex.step_token_budget }.not_to raise_error
      end

      it 'raises TokenBudgetExceeded when estimated input exceeds the cap' do
        long_message = 'a' * 400 # 400 chars => 100 estimated tokens
        ex = build_executor(
          messages: [{ role: :user, content: long_message }],
          extra:    { max_input_tokens: 50 }
        )
        expect { ex.step_token_budget }.to raise_error(Legion::LLM::TokenBudgetExceeded, /max_input_tokens/)
      end
    end

    context 'when session_max_tokens is configured' do
      before do
        Legion::Settings[:llm][:budget] = { session_max_tokens: 500 }
      end

      it 'passes when session is under the limit' do
        Legion::LLM::TokenTracker.record(input_tokens: 100, output_tokens: 100)
        ex = build_executor
        expect { ex.step_token_budget }.not_to raise_error
      end

      it 'raises TokenBudgetExceeded when session has exceeded the limit' do
        Legion::LLM::TokenTracker.record(input_tokens: 300, output_tokens: 250)
        ex = build_executor
        expect { ex.step_token_budget }.to raise_error(Legion::LLM::TokenBudgetExceeded, /session token budget exceeded/)
      end
    end

    context 'when an unexpected error occurs in the step' do
      it 'appends a warning instead of propagating the error' do
        allow(Legion::LLM::TokenTracker).to receive(:session_exceeded?).and_raise(RuntimeError, 'unexpected')
        ex = build_executor
        expect { ex.step_token_budget }.not_to raise_error
        expect(ex.warnings).not_to be_empty
        expect(ex.warnings.first[:type]).to eq(:token_budget_check_failed)
      end
    end

    context 'with system prompt contributing to input estimate' do
      it 'includes system prompt characters in the input estimate' do
        system_str = 'a' * 400 # 400 chars => ~100 tokens
        ex = build_executor(
          messages: [{ role: :user, content: 'hi' }],
          system:   system_str,
          extra:    { max_input_tokens: 50 }
        )
        expect { ex.step_token_budget }.to raise_error(Legion::LLM::TokenBudgetExceeded)
      end
    end
  end
end
