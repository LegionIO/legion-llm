# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM::Errors::NoLaneAvailable (P5)' do
  let(:described_class) { Legion::LLM::Errors::NoLaneAvailable }

  it 'inherits from LLMError' do
    expect(described_class.ancestors).to include(Legion::LLM::LLMError)
  end

  it 'is not retryable' do
    expect(described_class.new(filters: {}).retryable?).to be false
  end

  it 'accepts filters: kwarg and exposes it' do
    filters = { tiers: [:direct], providers: [:vllm] }
    err = described_class.new(filters: filters)
    expect(err.filters).to eq(filters)
  end

  it 'accepts trailing ** without error' do
    expect { described_class.new(filters: {}, extra_context: 'ignored') }.not_to raise_error
  end
end
