# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor do
  describe 'routing capability requirements' do
    it 'routes LegionIO streaming requests only to streaming tool-capable targets' do
      allow(Legion::LLM::Tools::Special).to receive(:pinned_definitions).and_return([
                                                                                      instance_double(
                                                                                        Legion::LLM::Types::ToolDefinition,
                                                                                        name: :ruby
                                                                                      )
                                                                                    ])

      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        routing:  { model: 'legionio' },
        stream:   true
      )

      state = described_class.new(request).send(:routing_request_state)

      expect(state[:intent][:capability]).to eq(:stream)
      expect(state[:intent][:required_capabilities]).to contain_exactly(:streaming, :tools)
    end
  end
end
