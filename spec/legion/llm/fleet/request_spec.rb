# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/transport/messages/fleet_request'
require 'legion/llm/transport/messages/fleet_response'
require 'legion/llm/transport/messages/fleet_error'

RSpec.describe 'retired legion-llm fleet transport messages' do
  it 'rejects the old FleetRequest authority class' do
    expect do
      Legion::LLM::Transport::Messages::FleetRequest.new
    end.to raise_error(NotImplementedError, /Legion::Extensions::Llm::Transport::Messages::FleetRequest/)
  end

  it 'rejects the old FleetResponse authority class' do
    expect do
      Legion::LLM::Transport::Messages::FleetResponse.new
    end.to raise_error(NotImplementedError, /Legion::Extensions::Llm::Transport::Messages::FleetResponse/)
  end

  it 'rejects the old FleetError authority class' do
    expect do
      Legion::LLM::Transport::Messages::FleetError.new
    end.to raise_error(NotImplementedError, /Legion::Extensions::Llm::Transport::Messages::FleetError/)
  end
end
