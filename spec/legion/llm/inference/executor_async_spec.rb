# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Executor do
  describe 'ASYNC_SAFE_STEPS' do
    subject(:async_safe) { described_class::ASYNC_SAFE_STEPS }

    it 'does not include context_store' do
      expect(async_safe).not_to include(:context_store)
    end

    it 'includes post_response' do
      expect(async_safe).to include(:post_response)
    end

    it 'includes knowledge_capture' do
      expect(async_safe).to include(:knowledge_capture)
    end

    it 'includes response_return' do
      expect(async_safe).to include(:response_return)
    end

    it 'does not include response_normalization' do
      expect(async_safe).not_to include(:response_normalization)
    end

    it 'does not include debate' do
      expect(async_safe).not_to include(:debate)
    end

    it 'does not include confidence_scoring' do
      expect(async_safe).not_to include(:confidence_scoring)
    end

    it 'does not include tool_calls' do
      expect(async_safe).not_to include(:tool_calls)
    end
  end

  describe '#async_post_enabled?' do
    let(:request) do
      Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  {}
      )
    end

    subject(:executor) { described_class.new(request) }

    context 'when pipeline_async_post_steps is true' do
      before { Legion::Settings[:llm][:pipeline_async_post_steps] = true }

      it 'returns true' do
        expect(executor.send(:async_post_enabled?)).to be(true)
      end
    end

    context 'when pipeline_async_post_steps is false' do
      before { Legion::Settings[:llm][:pipeline_async_post_steps] = false }

      it 'returns false' do
        expect(executor.send(:async_post_enabled?)).to be(false)
      end
    end

    context 'when pipeline_async_post_steps is not set' do
      before { Legion::Settings[:llm][:pipeline_async_post_steps] = nil }

      it 'returns false' do
        expect(executor.send(:async_post_enabled?)).to be(false)
      end
    end
  end
end
