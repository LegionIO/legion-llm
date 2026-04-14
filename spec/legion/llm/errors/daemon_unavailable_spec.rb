# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::DaemonUnavailableError do
  it 'is a subclass of LLMError' do
    expect(described_class.ancestors).to include(Legion::LLM::LLMError)
  end

  it 'is a StandardError' do
    expect(described_class.new('daemon down')).to be_a(StandardError)
  end

  it 'is not retryable' do
    expect(described_class.new('daemon down')).not_to be_retryable
  end

  it 'carries a message' do
    err = described_class.new('daemon at :7000 did not respond')
    expect(err.message).to eq('daemon at :7000 did not respond')
  end
end
