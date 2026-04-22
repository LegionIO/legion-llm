# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transport_stub'
require 'legion/llm/transport/exchanges/audit'

RSpec.describe Legion::LLM::Transport::Exchanges::Audit do
  subject(:exchange) { described_class.new }

  it 'returns llm.audit as the exchange name' do
    expect(exchange.exchange_name).to eq('llm.audit')
  end

  it 'returns topic as the exchange type' do
    expect(exchange.default_type).to eq('topic')
  end
end
