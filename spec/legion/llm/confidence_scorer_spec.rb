# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/quality/checker'
require 'legion/llm/quality/confidence/score'
require 'legion/llm/quality/confidence/scorer'

RSpec.describe Legion::LLM::Quality::Confidence::Scorer do
  def make_response(content)
    double('RawResponse', content: content)
  end

  let(:good_content) { 'The quick brown fox jumps over the lazy dog. ' * 5 }
  let(:good_response) { make_response(good_content) }

  describe '.score' do
    context 'caller-provided score' do
      it 'returns a ConfidenceScore with source :caller_provided' do
        result = described_class.score(good_response, confidence_score: 0.9)
        expect(result).to be_a(Legion::LLM::Quality::Confidence::Score)
        expect(result.source).to eq(:caller_provided)
        expect(result.score).to eq(0.9)
      end

      it 'clamps the caller-provided score to [0, 1]' do
        result = described_class.score(good_response, confidence_score: 1.5)
        expect(result.score).to eq(1.0)
      end

      it 'stores the caller value in signals' do
        result = described_class.score(good_response, confidence_score: 0.75)
        expect(result.signals[:caller_provided]).to eq(0.75)
      end
    end

    context 'logprobs available' do
      # Use a real Struct so method_defined? works (RSpec doubles use message interception,
      # not actual method definitions, so method_defined? returns false for them).
      let(:response_class_with_logprobs) do
        Struct.new(:content, :logprobs)
      end

      let(:response_with_logprobs) do
        response_class_with_logprobs.new(good_content, [-0.1, -0.2, -0.05])
      end

      it 'returns a ConfidenceScore with source :logprobs' do
        result = described_class.score(response_with_logprobs)
        expect(result.source).to eq(:logprobs)
      end

      it 'computes score from average log-probability' do
        # avg = (-0.1 + -0.2 + -0.05) / 3 = -0.1167; exp(-0.1167) ≈ 0.89
        result = described_class.score(response_with_logprobs)
        expect(result.score).to be_within(0.05).of(0.89)
      end
    end

    context 'logprobs nil or empty' do
      let(:nil_logprobs_class) { Struct.new(:content, :logprobs) }
      let(:response_nil_logprobs) { nil_logprobs_class.new(good_content, nil) }
      let(:response_empty_logprobs) { nil_logprobs_class.new(good_content, []) }

      it 'falls through to heuristic when logprobs is nil' do
        result = described_class.score(response_nil_logprobs)
        expect(result.source).to eq(:heuristic)
      end

      it 'falls through to heuristic when logprobs is empty' do
        result = described_class.score(response_empty_logprobs)
        expect(result.source).to eq(:heuristic)
      end
    end

    context 'heuristic scoring' do
      it 'returns a high score for a clean response' do
        result = described_class.score(good_response)
        expect(result.source).to eq(:heuristic)
        expect(result.score).to eq(1.0)
        expect(result.band).to eq(:very_high)
      end

      it 'returns score 0.0 for an empty response' do
        result = described_class.score(make_response(''))
        expect(result.score).to eq(0.0)
        expect(result.signals[:empty]).to be true
      end

      it 'applies a refusal penalty' do
        refusal_text = "I can't help with that request.#{' padding' * 30}"
        result = described_class.score(make_response(refusal_text), quality_threshold: 1)
        expect(result.signals[:refusal]).to be true
        expect(result.score).to be < 1.0
      end

      it 'applies a truncation penalty' do
        # Content must be >= 100 chars, end with word chars (not punctuation/close brackets)
        # to trigger the truncation heuristic.
        truncated = "This is a response that appears to be cut off in the middle of a word like somethi#{'x' * 25}"
        result = described_class.score(make_response(truncated), quality_threshold: 1)
        expect(result.signals[:truncated]).to be true
        expect(result.score).to be < 1.0
      end

      it 'applies a repetition penalty' do
        repeated = 'ABCDEFGHIJKLMNOPQRST' * 10
        result = described_class.score(make_response(repeated), quality_threshold: 1)
        expect(result.signals[:repetition]).to be true
        expect(result.score).to be < 1.0
      end

      it 'applies a too_short penalty' do
        result = described_class.score(make_response('ok'), quality_threshold: 100)
        expect(result.signals[:too_short]).to be true
        expect(result.score).to be < 1.0
      end

      it 'applies a json_parse_failure penalty when json_expected' do
        result = described_class.score(make_response('not json {broken'), json_expected: true, quality_threshold: 1)
        expect(result.signals[:json_parse_failure]).to be true
        expect(result.score).to be < 1.0
      end

      it 'gives a structured_output bonus for valid JSON when json_expected' do
        # Use a valid JSON object (single root) with enough content to pass quality checks.
        json_content = '{"summary":"The quick brown fox jumps over the lazy dog.","status":"ok","items":["a","b","c"]}'
        result_json  = described_class.score(make_response(json_content), json_expected: true, quality_threshold: 1)
        result_plain = described_class.score(make_response(json_content), json_expected: false, quality_threshold: 1)
        expect(result_json.score).to be >= result_plain.score
        expect(result_json.signals[:structured_output_valid]).to be true
      end

      it 'penalises hedging language' do
        hedged = "I think this might work. Perhaps you should try. #{' word' * 20}."
        result = described_class.score(make_response(hedged), quality_threshold: 1)
        expect(result.signals[:hedging]).to be_a(Integer)
        expect(result.signals[:hedging]).to be > 0
        expect(result.score).to be < 1.0
      end

      it 'caps hedging penalty at 0.3' do
        # Build content with many unique hedge phrases to avoid repetition detection.
        hedges = [
          'I think this is correct.',
          'I believe this may apply.',
          'It seems like it could work.',
          'Perhaps this is the answer.',
          'Maybe we should try this approach.',
          'I am not certain about this result.',
          'It appears to be accurate.',
          'Possibly this is the right path.',
          'I assume this is valid.',
          'Probably the best solution here.',
          'I guess we can proceed this way.',
          'Could be the intended behavior.'
        ]
        heavily_hedged = hedges.join(' ')
        result = described_class.score(make_response(heavily_hedged), quality_threshold: 1)
        # Penalty is capped at 0.3 for hedging; score should still be >= 0.7
        expect(result.score).to be >= 0.7
        expect(result.signals[:hedging]).to be > 0
      end

      it 'uses a pre-computed quality_result to avoid redundant checks' do
        quality_result = Legion::LLM::Quality::Checker::QualityResult.new(passed: false, failures: [:refusal])
        result = described_class.score(good_response, quality_result: quality_result, quality_threshold: 1)
        expect(result.signals[:refusal]).to be true
      end
    end

    context 'configurable band boundaries via options' do
      it 'classifies the same score differently with custom bands' do
        # score 0.35 is :medium with default bands (>= 0.3 boundary)
        default_result = described_class.score(make_response('ok'), confidence_score: 0.35)
        expect(default_result.band).to eq(:low)

        # With a high bar, 0.35 is still :very_low
        high_bar_result = described_class.score(
          make_response('ok'),
          confidence_score: 0.35,
          confidence_bands: { low: 0.4, medium: 0.6, high: 0.8, very_high: 0.95 }
        )
        expect(high_bar_result.band).to eq(:very_low)
      end
    end

    context 'configurable band boundaries via Settings' do
      before do
        allow(Legion::Settings).to receive(:[]).with(:llm).and_return(
          { confidence: { bands: { low: 0.2, medium: 0.4, high: 0.6, very_high: 0.8 } } }
        )
      end

      it 'reads bands from Legion::Settings[:llm][:confidence][:bands]' do
        # score 0.75: with default bands (very_high >= 0.9) this is :high
        # with custom bands (very_high >= 0.8) this is also :high (0.75 < 0.8)
        # use 0.85 which is >= 0.8 -> :very_high under custom bands, but :high under default
        result_custom = described_class.score(make_response('ok'), confidence_score: 0.85)
        expect(result_custom.band).to eq(:very_high)
      end
    end

    context 'response without #content method' do
      it 'treats it as empty and returns score 0.0' do
        bare_response = double('BareResponse')
        allow(bare_response).to receive(:respond_to?).with(:content).and_return(false)
        allow(bare_response).to receive(:respond_to?).with(:logprobs).and_return(false)
        allow(bare_response).to receive(:respond_to?).with(:metadata).and_return(false)
        result = described_class.score(bare_response)
        expect(result.score).to eq(0.0)
      end
    end
  end
end
