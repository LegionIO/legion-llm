# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/transport/messages/fleet_error'

RSpec.describe Legion::LLM::Transport::Messages::FleetError do
  it 'is retired in favor of the lex-llm shared fleet error envelope' do
    expect do
      described_class.new
    end.to raise_error(NotImplementedError, /Legion::Extensions::Llm::Transport::Messages::FleetError/)
  end
end
