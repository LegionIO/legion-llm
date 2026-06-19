# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM::Errors::EscalationExhausted (P5)' do
  let(:described_class) { Legion::LLM::Errors::EscalationExhausted }

  it 'inherits from LLMError' do
    expect(described_class.ancestors).to include(Legion::LLM::LLMError)
  end

  it 'is not retryable at the library layer' do
    err = described_class.new(attempts: 3, tried_lanes: [], last_error: nil)
    expect(err.retryable?).to be false
  end

  it 'accepts attempts:, tried_lanes:, last_error: kwargs and exposes them' do
    last = RuntimeError.new('provider down')
    err = described_class.new(attempts: 3, tried_lanes: ['direct:vllm:default:inference:gemma-12b'], last_error: last)
    expect(err.attempts).to eq(3)
    expect(err.tried_lanes).to eq(['direct:vllm:default:inference:gemma-12b'])
    expect(err.last_error).to eq(last)
  end

  it 'accepts trailing ** without error' do
    expect { described_class.new(attempts: 1, tried_lanes: [], last_error: nil, extra: 'ignored') }.not_to raise_error
  end
end
