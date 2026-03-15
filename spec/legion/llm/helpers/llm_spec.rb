# frozen_string_literal: true

require 'spec_helper'

# Stub the namespace that only exists in the full LegionIO framework
module Legion
  module Extensions
    module Helpers
    end
  end
end

require 'legion/llm/helpers/llm'

RSpec.describe Legion::Extensions::Helpers::LLM do
  let(:test_class) { Class.new { include Legion::Extensions::Helpers::LLM } }
  let(:instance) { test_class.new }

  let(:mock_chat) { instance_double('RubyLLM::Chat') }
  let(:mock_response) { double('response', content: 'ok') }

  before do
    allow(Legion::LLM).to receive(:chat).and_return(mock_chat)
    allow(mock_chat).to receive(:with_instructions).and_return(mock_chat)
    allow(mock_chat).to receive(:with_tools).and_return(mock_chat)
    allow(mock_chat).to receive(:ask).and_return(mock_response)
  end

  describe '#llm_chat' do
    it 'compresses instructions when compress level is provided' do
      instance.llm_chat('hello', instructions: 'The very important system prompt', compress: 2)
      expect(mock_chat).to have_received(:with_instructions).with('important system prompt')
    end

    it 'compresses message when compress level is provided' do
      instance.llm_chat('The very important question', compress: 1)
      expect(mock_chat).to have_received(:ask).with('important question')
    end

    it 'does not compress when compress is 0' do
      instance.llm_chat('The very important question', compress: 0)
      expect(mock_chat).to have_received(:ask).with('The very important question')
    end

    it 'does not compress by default' do
      instance.llm_chat('The very important question')
      expect(mock_chat).to have_received(:ask).with('The very important question')
    end
  end
end
