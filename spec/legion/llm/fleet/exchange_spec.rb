# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/fleet/exchange'

RSpec.describe Legion::LLM::Fleet::Exchange do
  subject(:exchange) { described_class.new }

  it 'returns llm.request as the exchange name' do
    expect(exchange.exchange_name).to eq('llm.request')
  end

  it 'returns topic as the exchange type' do
    expect(exchange.default_type).to eq('topic')
  end
end
