# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::McpToolAdapter do
  let(:logger) { instance_double('Logger', info: nil) }

  let(:tool_class) do
    Class.new do
      define_singleton_method(:tool_name) { 'legion.test.echo' }
      define_singleton_method(:description) { 'Echo a string' }

      def self.call(**args)
        { content: [{ text: "echo=#{args[:value]}" }] }
      end
    end
  end

  it 'logs tool execution and the returned content' do
    adapter = described_class.new(tool_class)
    allow(adapter).to receive(:log).and_return(logger)

    result = adapter.execute(value: 'hello')

    expect(result).to eq('echo=hello')
    expect(logger).to have_received(:info).with(
      include('[llm][tools] adapter.execute', 'name=legion_test_echo', 'value')
    )
    expect(logger).to have_received(:info).with(
      include('[llm][tools] adapter.result', 'name=legion_test_echo', 'echo=hello')
    )
  end
end
