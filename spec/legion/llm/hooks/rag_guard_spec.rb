# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/hooks/rag_guard'

RSpec.describe Legion::LLM::Hooks::RagGuard do
  let(:response) { 'Paris is the capital of France.' }
  let(:context)  { 'France is a country in Western Europe. Its capital city is Paris.' }

  describe '.check_rag_faithfulness' do
    context 'when lex-eval is unavailable' do
      before do
        hide_const('Legion::Extensions::Eval::Client') if defined?(Legion::Extensions::Eval::Client)
      end

      it 'returns faithful: true with reason :eval_unavailable' do
        result = described_class.check_rag_faithfulness(response: response, context: context)
        expect(result[:faithful]).to be true
        expect(result[:reason]).to eq(:eval_unavailable)
      end
    end

    context 'when lex-eval is available' do
      let(:mock_client) { instance_double('Legion::Extensions::Eval::Client') }

      before do
        stub_const('Legion::Extensions::Eval::Client', Class.new)
        allow(Legion::Extensions::Eval::Client).to receive(:new).and_return(mock_client)
      end

      context 'with a faithful response (all scores above threshold)' do
        before do
          allow(mock_client).to receive(:run_evaluation) do |evaluator_name:, **|
            score = evaluator_name == :faithfulness ? 0.92 : 0.85
            { summary: { avg_score: score } }
          end
        end

        it 'returns faithful: true with scores hash' do
          result = described_class.check_rag_faithfulness(response: response, context: context)
          expect(result[:faithful]).to be true
          expect(result[:scores][:faithfulness]).to eq(0.92)
          expect(result[:scores][:rag_relevancy]).to eq(0.85)
          expect(result[:flagged_evaluators]).to be_empty
        end

        it 'includes a details string' do
          result = described_class.check_rag_faithfulness(response: response, context: context)
          expect(result[:details]).to include('passed')
        end
      end

      context 'with an unfaithful response (scores below threshold)' do
        before do
          allow(mock_client).to receive(:run_evaluation) do |evaluator_name:, **|
            score = evaluator_name == :faithfulness ? 0.3 : 0.45
            { summary: { avg_score: score } }
          end
        end

        it 'returns faithful: false' do
          result = described_class.check_rag_faithfulness(response: response, context: context)
          expect(result[:faithful]).to be false
        end

        it 'lists both evaluators as flagged' do
          result = described_class.check_rag_faithfulness(response: response, context: context)
          expect(result[:flagged_evaluators]).to contain_exactly(:faithfulness, :rag_relevancy)
        end

        it 'includes a details string with failed status' do
          result = described_class.check_rag_faithfulness(response: response, context: context)
          expect(result[:details]).to include('failed')
        end
      end

      context 'with a custom threshold' do
        before do
          allow(mock_client).to receive(:run_evaluation).and_return({ summary: { avg_score: 0.65 } })
        end

        it 'passes when score exceeds custom threshold' do
          result = described_class.check_rag_faithfulness(
            response: response, context: context, threshold: 0.6
          )
          expect(result[:faithful]).to be true
          expect(result[:flagged_evaluators]).to be_empty
        end

        it 'fails when score is below custom threshold' do
          result = described_class.check_rag_faithfulness(
            response: response, context: context, threshold: 0.8
          )
          expect(result[:faithful]).to be false
        end
      end

      context 'with custom evaluators' do
        let(:custom_evaluators) { [:hallucination] }

        before do
          allow(mock_client).to receive(:run_evaluation).and_return({ summary: { avg_score: 0.9 } })
        end

        it 'only runs the specified evaluators' do
          result = described_class.check_rag_faithfulness(
            response: response, context: context, evaluators: custom_evaluators
          )
          expect(result[:scores].keys).to eq([:hallucination])
          expect(mock_client).to have_received(:run_evaluation).once
        end
      end

      context 'when an evaluator raises an error' do
        before do
          allow(mock_client).to receive(:run_evaluation).and_raise(StandardError, 'LLM unavailable')
        end

        it 'returns 0.0 score for failed evaluators and marks them as flagged' do
          result = described_class.check_rag_faithfulness(response: response, context: context)
          expect(result[:scores][:faithfulness]).to eq(0.0)
          expect(result[:flagged_evaluators]).to include(:faithfulness)
        end
      end

      context 'when reading threshold from settings' do
        before do
          allow(Legion::Settings).to receive(:dig).with(:llm, :rag_guard, :threshold).and_return(0.5)
          allow(Legion::Settings).to receive(:dig).with(:llm, :rag_guard, :evaluators).and_return(nil)
          allow(mock_client).to receive(:run_evaluation).and_return({ summary: { avg_score: 0.6 } })
        end

        it 'uses the settings threshold' do
          result = described_class.check_rag_faithfulness(response: response, context: context)
          expect(result[:faithful]).to be true
        end
      end
    end
  end
end
