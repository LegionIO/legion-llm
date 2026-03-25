# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline Steps::KnowledgeCapture' do
  let(:request) do
    Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'How does X work?' }],
      routing:  { provider: :anthropic, model: 'test-model' }
    )
  end

  let(:executor) do
    ex = Legion::LLM::Pipeline::Executor.new(request)
    allow(ex).to receive(:step_provider_call).and_return(
      { role: :assistant, content: 'X works by doing Y' }
    )
    allow(ex).to receive(:step_response_normalization).and_return(nil)
    ex
  end

  describe '#step_knowledge_capture' do
    context 'when Apollo is not defined' do
      before do
        hide_const('Legion::Extensions::Apollo::Helpers::Writeback') if defined?(Legion::Extensions::Apollo::Helpers::Writeback)
      end

      it 'skips silently' do
        expect { executor.send(:step_knowledge_capture) }.not_to raise_error
      end
    end

    context 'when Apollo Writeback is defined' do
      before do
        stub_const('Legion::Extensions::Apollo::Helpers::Writeback', Module.new)
        allow(Legion::Extensions::Apollo::Helpers::Writeback).to receive(:evaluate_and_route)
      end

      it 'calls evaluate_and_route' do
        # Need to run provider_call first to populate @raw_response
        executor.call
        expect(Legion::Extensions::Apollo::Helpers::Writeback).to have_received(:evaluate_and_route)
      end
    end

    context 'when writeback raises an error' do
      before do
        stub_const('Legion::Extensions::Apollo::Helpers::Writeback', Module.new)
        allow(Legion::Extensions::Apollo::Helpers::Writeback).to receive(:evaluate_and_route)
          .and_raise(RuntimeError, 'boom')
      end

      it 'adds a warning instead of failing' do
        executor.call
        expect(executor.warnings).to include(match(/knowledge_capture error/))
      end
    end
  end
end
