# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/metering/exchange'

RSpec.describe Legion::LLM::Metering::Exchange do
  subject(:exchange) { described_class.new }

  it 'returns llm.metering as the exchange name' do
    expect(exchange.exchange_name).to eq('llm.metering')
  end

  it 'returns topic as the exchange type' do
    expect(exchange.default_type).to eq('topic')
  end
end
