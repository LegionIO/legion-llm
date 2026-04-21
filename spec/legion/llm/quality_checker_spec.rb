# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/quality/checker'

RSpec.describe Legion::LLM::Quality::Checker do
  let(:good_response) { double('Response', content: 'The quick brown fox jumps over the lazy dog. ' * 5, role: :assistant) }
  let(:empty_response) { double('Response', content: '', role: :assistant) }
  let(:nil_response) { double('Response', content: nil, role: :assistant) }
  let(:short_response) { double('Response', content: 'ok', role: :assistant) }

  let(:repetitive_response) do
    repeated = 'ABCDEFGHIJKLMNOPQRST' * 10
    double('Response', content: repeated, role: :assistant)
  end

  describe '.check' do
    context 'with a good response' do
      it 'passes all checks' do
        result = described_class.check(good_response)
        expect(result.passed).to be true
        expect(result.failures).to be_empty
      end
    end

    context 'with empty content' do
      it 'fails with :empty_response' do
        result = described_class.check(empty_response)
        expect(result.passed).to be false
        expect(result.failures).to include(:empty_response)
      end
    end

    context 'with nil content' do
      it 'fails with :empty_response' do
        result = described_class.check(nil_response)
        expect(result.passed).to be false
        expect(result.failures).to include(:empty_response)
      end
    end

    context 'with short content' do
      it 'fails with :too_short when below threshold' do
        result = described_class.check(short_response, quality_threshold: 10)
        expect(result.passed).to be false
        expect(result.failures).to include(:too_short)
      end

      it 'passes when above threshold' do
        result = described_class.check(short_response, quality_threshold: 1)
        expect(result.passed).to be true
      end
    end

    context 'with repetitive content' do
      it 'fails with :repetition' do
        result = described_class.check(repetitive_response)
        expect(result.passed).to be false
        expect(result.failures).to include(:repetition)
      end
    end

    context 'with json_expected and invalid JSON content' do
      let(:non_json_response) { double('Response', content: 'not json {broken', role: :assistant) }

      it 'fails with :json_parse_failure' do
        result = described_class.check(non_json_response, json_expected: true)
        expect(result.passed).to be false
        expect(result.failures).to include(:json_parse_failure)
      end
    end

    context 'with json_expected and valid JSON content' do
      let(:json_response) { double('Response', content: '{"key": "value"}', role: :assistant) }

      it 'passes json check' do
        result = described_class.check(json_response, json_expected: true)
        expect(result.failures).not_to include(:json_parse_failure)
      end
    end
  end

  describe 'truncation detection' do
    it 'detects truncated content ending mid-word' do
      text = "This is a response that was cut off mid sente#{'x' * 60}"
      response = double('Response', content: text, role: :assistant)
      result = described_class.check(response, quality_threshold: 1)
      expect(result.failures).to include(:truncated)
    end

    it 'does not flag content ending with punctuation' do
      result = described_class.check(good_response, quality_threshold: 1)
      expect(result.failures).not_to include(:truncated)
    end

    it 'does not flag short content' do
      response = double('Response', content: 'abc', role: :assistant)
      result = described_class.check(response, quality_threshold: 1)
      expect(result.failures).not_to include(:truncated)
    end
  end

  describe 'refusal detection' do
    it 'detects refusal patterns' do
      text = "I can't help with that request. It goes against my guidelines.#{' padding' * 20}"
      response = double('Response', content: text, role: :assistant)
      result = described_class.check(response, quality_threshold: 1)
      expect(result.failures).to include(:refusal)
    end

    it 'detects as-an-AI pattern' do
      text = "As an AI language model, I cannot do that.#{' padding' * 20}"
      response = double('Response', content: text, role: :assistant)
      result = described_class.check(response, quality_threshold: 1)
      expect(result.failures).to include(:refusal)
    end

    it 'does not flag normal responses' do
      result = described_class.check(good_response, quality_threshold: 1)
      expect(result.failures).not_to include(:refusal)
    end
  end

  describe 'pluggable quality_check' do
    it 'runs custom check in addition to built-ins' do
      custom = ->(resp) { resp.content.include?('SELECT') }
      response = double('Response', content: 'The quick brown fox jumps over the lazy dog. ' * 5, role: :assistant)

      result = described_class.check(response, quality_check: custom)
      expect(result.passed).to be false
      expect(result.failures).to include(:custom_check_failed)
    end

    it 'passes when custom check returns truthy' do
      custom = ->(resp) { resp.content.length > 10 }
      result = described_class.check(good_response, quality_check: custom)
      expect(result.passed).to be true
    end
  end
end
