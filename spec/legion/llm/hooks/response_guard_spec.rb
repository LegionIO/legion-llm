# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/hooks/rag_guard'
require 'legion/llm/hooks/response_guard'

RSpec.describe Legion::LLM::Hooks::ResponseGuard do
  let(:response) { 'The sky is blue.' }
  let(:context)  { 'Scientific studies confirm the sky appears blue due to Rayleigh scattering.' }

  describe '.guard_response' do
    context 'with :rag guard and context present' do
      before do
        allow(Legion::LLM::Hooks::RagGuard).to receive(:check_rag_faithfulness).and_return(
          { faithful: true, scores: { faithfulness: 0.9, rag_relevancy: 0.88 }, flagged_evaluators: [], details: 'passed' }
        )
      end

      it 'dispatches to RagGuard and returns passed: true' do
        result = described_class.guard_response(response: response, context: context, guards: [:rag])
        expect(result[:passed]).to be true
        expect(result[:guards][:rag][:faithful]).to be true
      end

      it 'calls RagGuard with response and context' do
        described_class.guard_response(response: response, context: context, guards: [:rag])
        expect(Legion::LLM::Hooks::RagGuard).to have_received(:check_rag_faithfulness)
          .with(response: response, context: context)
      end
    end

    context 'with :rag guard and no context' do
      it 'skips RAG guard and returns reason :no_context' do
        result = described_class.guard_response(response: response, context: nil, guards: [:rag])
        expect(result[:passed]).to be true
        expect(result[:guards][:rag][:reason]).to eq(:no_context)
      end

      it 'does not call RagGuard when context is nil' do
        allow(Legion::LLM::Hooks::RagGuard).to receive(:check_rag_faithfulness)
        described_class.guard_response(response: response, context: nil, guards: [:rag])
        expect(Legion::LLM::Hooks::RagGuard).not_to have_received(:check_rag_faithfulness)
      end
    end

    context 'when rag guard reports unfaithful' do
      before do
        allow(Legion::LLM::Hooks::RagGuard).to receive(:check_rag_faithfulness).and_return(
          { faithful: false, scores: { faithfulness: 0.2 }, flagged_evaluators: [:faithfulness], details: 'failed' }
        )
      end

      it 'returns passed: false' do
        result = described_class.guard_response(response: response, context: context, guards: [:rag])
        expect(result[:passed]).to be false
        expect(result[:guards][:rag][:faithful]).to be false
      end
    end

    context 'with an unknown guard name' do
      it 'skips unknown guards without raising' do
        result = described_class.guard_response(response: response, context: context, guards: [:unknown_guard])
        expect(result[:passed]).to be true
        expect(result[:guards]).to be_empty
      end
    end

    context 'with empty guards list' do
      it 'returns passed: true with no guard results' do
        result = described_class.guard_response(response: response, context: context, guards: [])
        expect(result[:passed]).to be true
        expect(result[:guards]).to be_empty
      end
    end

    context 'when guard raises an unexpected error' do
      before do
        allow(Legion::LLM::Hooks::RagGuard).to receive(:check_rag_faithfulness)
          .and_raise(RuntimeError, 'unexpected')
      end

      it 'returns passed: true with empty guards on error' do
        result = described_class.guard_response(response: response, context: context, guards: [:rag])
        expect(result[:passed]).to be true
        expect(result[:guards]).to be_empty
      end
    end
  end
end
