# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/transport/messages/fleet_response'

RSpec.describe Legion::LLM::Transport::Messages::FleetResponse do
  it 'is retired in favor of the lex-llm shared fleet response envelope' do
    expect do
      described_class.new
    end.to raise_error(NotImplementedError, /Legion::Extensions::Llm::Transport::Messages::FleetResponse/)
  end
end
