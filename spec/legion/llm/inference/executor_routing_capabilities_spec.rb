# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor do
  describe 'routing capability requirements' do
    before do
      allow(Legion::LLM::Tools::Special).to receive(:pinned_definitions).and_return([
                                                                                      instance_double(
                                                                                        Legion::LLM::Types::ToolDefinition,
                                                                                        name: :ruby,
                                                                                        to_h: { name: 'ruby' }
                                                                                      )
                                                                                    ])
    end

    it 'does not require :tools for plain non-streaming requests just because pinned tools exist' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        routing:  { model: 'legionio' },
        stream:   false
      )

      state = described_class.new(request).send(:routing_request_state)

      expect(state[:intent][:operation]).to eq(:chat)
      expect(state[:intent][:effort]).to eq(:moderate)
      expect(Array(state[:intent][:required_capabilities])).not_to include(:tools)
      expect(Array(state[:intent][:required_capabilities])).not_to include(:thinking)
      expect(state[:intent]).not_to have_key(:capability)
    end

    it 'does not require :tools for plain streaming requests just because pinned tools exist' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        routing:  { model: 'legionio' },
        stream:   true
      )

      state = described_class.new(request).send(:routing_request_state)

      expect(state[:intent][:operation]).to eq(:stream)
      expect(state[:intent][:effort]).to eq(:moderate)
      expect(state[:intent][:required_capabilities]).to include(:streaming)
      expect(state[:intent][:required_capabilities]).not_to include(:tools)
      expect(state[:intent]).not_to have_key(:capability)
    end

    it 'requires :tools when the request explicitly includes client tools' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        routing:  { model: 'legionio' },
        tools:    [{ name: 'client_echo', description: 'echo', input_schema: { type: 'object', properties: {} } }]
      )

      state = described_class.new(request).send(:routing_request_state)

      expect(state[:intent][:required_capabilities]).to include(:tools)
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

      expect(Array(state[:intent][:required_capabilities])).not_to include(:thinking)
    end

    it 'ignores payload client_model as a routing pin when body routing hints are disabled' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  {},
        metadata: { client_model: 'gpt-5.5' }
      )

      state = described_class.new(request).send(:routing_request_state)

      expect(state[:model]).to be_nil
    end

    it 'honors payload client_model only when body routing hints are enabled' do
      Legion::Settings[:llm][:routing][:allow_body_routing_hints] = true
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  {},
        metadata: { client_model: 'gpt-5.5' }
      )

      state = described_class.new(request).send(:routing_request_state)

      expect(state[:model]).to eq('gpt-5.5')
    end

    it 'still honors an explicit Legion routing model over payload auto aliases' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { model: 'gemma-4-31b-it' },
        metadata: { client_model: 'auto' }
      )

      state = described_class.new(request).send(:routing_request_state)

      expect(state[:model]).to eq('gemma-4-31b-it')
    end
  end
end
