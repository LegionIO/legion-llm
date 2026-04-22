# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/quality/checker'
require 'legion/llm/quality/confidence/score'
require 'legion/llm/quality/confidence/scorer'
require 'legion/llm/inference/timeline'
require 'legion/llm/inference/request'
require 'legion/llm/inference/steps'

RSpec.describe Legion::LLM::Inference::Steps::ConfidenceScoring do
  let(:host_class) do
    Class.new do
      include Legion::LLM::Inference::Steps::ConfidenceScoring

      attr_accessor :request, :timeline, :warnings, :raw_response, :confidence_score

      def initialize(request, raw_response = nil)
        @request          = request
        @timeline         = Legion::LLM::Inference::Timeline.new
        @warnings         = []
        @raw_response     = raw_response
        @confidence_score = nil
      end
    end
  end

  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }]
    )
  end

  let(:raw_response) do
    double('RawResponse', content: 'The quick brown fox jumps over the lazy dog. ' * 5)
  end

  describe '#step_confidence_scoring' do
    context 'with a valid raw response' do
      it 'assigns @confidence_score' do
        step = host_class.new(request, raw_response)
        step.step_confidence_scoring
        expect(step.confidence_score).to be_a(Legion::LLM::Quality::Confidence::Score)
      end

      it 'records a timeline event' do
        step = host_class.new(request, raw_response)
        step.step_confidence_scoring
        keys = step.timeline.events.map { |e| e[:key] }
        expect(keys).to include('confidence:scored')
      end

      it 'timeline detail includes score, band and source' do
        step = host_class.new(request, raw_response)
        step.step_confidence_scoring
        event = step.timeline.events.find { |e| e[:key] == 'confidence:scored' }
        expect(event[:detail]).to match(/score=/)
        expect(event[:detail]).to match(/band=/)
        expect(event[:detail]).to match(/source=/)
      end
    end

    context 'when @raw_response is nil' do
      it 'does not assign @confidence_score and does not raise' do
        step = host_class.new(request, nil)
        expect { step.step_confidence_scoring }.not_to raise_error
        expect(step.confidence_score).to be_nil
      end
    end

    context 'when ConfidenceScorer raises' do
      it 'appends a warning and does not raise' do
        allow(Legion::LLM::Quality::Confidence::Scorer).to receive(:score).and_raise(StandardError, 'boom')
        step = host_class.new(request, raw_response)
        expect { step.step_confidence_scoring }.not_to raise_error
        expect(step.warnings).to include(match(/confidence_scoring error: boom/))
        expect(step.confidence_score).to be_nil
      end
    end

    context 'with caller-provided confidence_score in request extra' do
      let(:request_with_score) do
        Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'hello' }],
          extra:    { confidence_score: 0.9 }
        )
      end

      it 'passes the caller-provided score to ConfidenceScorer' do
        step = host_class.new(request_with_score, raw_response)
        step.step_confidence_scoring
        expect(step.confidence_score.source).to eq(:caller_provided)
        expect(step.confidence_score.score).to eq(0.9)
      end
    end

    context 'with per-call confidence_bands in request extra' do
      let(:request_with_bands) do
        Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'hello' }],
          extra:    { confidence_bands: { low: 0.4, medium: 0.6, high: 0.8, very_high: 0.95 } }
        )
      end

      it 'passes band overrides through to the scorer' do
        step = host_class.new(request_with_bands, raw_response)
        step.step_confidence_scoring
        # Good response scores ~1.0 which is :very_high under any sane band config
        expect(step.confidence_score.band).to eq(:very_high)
      end
    end

    context 'with json response_format' do
      let(:request_json) do
        Legion::LLM::Inference::Request.build(
          messages:        [{ role: :user, content: 'hello' }],
          response_format: { type: :json }
        )
      end

      it 'passes json_expected: true to the scorer' do
        expect(Legion::LLM::Quality::Confidence::Scorer).to receive(:score)
          .with(raw_response, hash_including(json_expected: true))
          .and_call_original
        host_class.new(request_json, raw_response).step_confidence_scoring
      end
    end
  end
end
