# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::StickyHelpers do
  let(:host_class) do
    Class.new do
      include Legion::LLM::Inference::Steps::StickyHelpers
    end
  end

  subject(:host) { host_class.new }

  it 'honors tool sticky settings' do
    Legion::Settings.set_prop(:llm, {
                                tool_sticky: {
                                  enabled:              false,
                                  trigger_turns:        4,
                                  execution_tool_calls: 9,
                                  max_history_entries:  33,
                                  max_result_length:    1234,
                                  max_args_length:      321
                                }
                              })

    expect(host.send(:sticky_enabled?)).to be(false)
    expect(host.send(:trigger_sticky_turns)).to eq(4)
    expect(host.send(:execution_sticky_tool_calls)).to eq(9)
    expect(host.send(:max_history_entries)).to eq(33)
    expect(host.send(:max_result_length)).to eq(1234)
    expect(host.send(:max_args_length)).to eq(321)
  end
end
