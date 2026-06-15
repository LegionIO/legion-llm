# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor do
  describe 'routing capability requirements' do
    before do
      allow(Legion::LLM::Tools::Special).to receive(:pinned_definitions).and_return([
                                                                                      instance_double(
                                                                                        Legion::LLM::Types::ToolDefinition,
                                                                                        name: :ruby
                                                                                      )
                                                                                    ])
    end

    it 'routes non-streaming tool requests with operation: :chat and required_capabilities: [:tools]' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        routing:  { model: 'legionio' },
        stream:   false
      )

      state = described_class.new(request).send(:routing_request_state)

      expect(state[:intent][:operation]).to eq(:chat)
      expect(state[:intent][:effort]).to eq(:moderate)
      expect(state[:intent][:required_capabilities]).to include(:tools)
      expect(state[:intent][:required_capabilities]).not_to include(:thinking)
      expect(state[:intent]).not_to have_key(:capability)
    end

    it 'routes streaming tool requests with operation: :stream and required_capabilities including :streaming and :tools' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        routing:  { model: 'legionio' },
        stream:   true
      )

      state = described_class.new(request).send(:routing_request_state)

      expect(state[:intent][:operation]).to eq(:stream)
      expect(state[:intent][:effort]).to eq(:moderate)
      expect(state[:intent][:required_capabilities]).to include(:streaming, :tools)
      expect(state[:intent]).not_to have_key(:capability)
    end

    it 'includes :thinking in required_capabilities only for explicit thinking requests' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'think this through' }],
        routing:  { model: 'legionio' },
        thinking: { effort: :medium, budget: 1024 }
      )

      state = described_class.new(request).send(:routing_request_state)

      expect(state[:intent][:required_capabilities]).to include(:thinking)
    end

    it 'does not include :thinking for requests without explicit thinking config' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'think this through' }],
        routing:  { model: 'legionio' },
        stream:   false
      )

      state = described_class.new(request).send(:routing_request_state)

      expect(state[:intent][:required_capabilities]).not_to include(:thinking)
    end
  end
end
