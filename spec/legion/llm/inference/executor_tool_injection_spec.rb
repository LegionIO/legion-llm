# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor do
  let(:tool_definition) do
    Legion::LLM::Types::ToolDefinition.build(name: 'my_tool', description: 'My tool')
  end

  let(:request_with_tools) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'use a tool' }],
      tools:    [tool_definition],
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
    )
  end

  let(:request_empty_tools) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'no tools please' }],
      tools:    [],
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
    )
  end

  describe '#native_tool_definitions' do
    context 'when @request.tools is a non-empty array' do
      it 'includes request tools as native definitions' do
        executor = described_class.new(request_with_tools)
        expect(executor.send(:native_tool_definitions).map(&:name)).to include('my_tool')
      end
    end

    context 'when @request.tools is an empty array []' do
      it 'does not add registry tools' do
        registry_tool = Class.new do
          define_singleton_method(:tool_name) { 'registry_tool' }
          define_singleton_method(:description) { 'Registry tool' }
          define_singleton_method(:input_schema) { {} }
        end
        registry_mod = Module.new do
          define_singleton_method(:tools) { [registry_tool] }
          define_singleton_method(:deferred_tools) { [] }
        end
        stub_const('Legion::Tools::Registry', registry_mod)

        executor = described_class.new(request_empty_tools)
        expect(executor.send(:native_tool_definitions)).to eq([])
      end
    end

    context 'when @request.tools is a non-Array (nil via direct construction)' do
      it 'adds registry tools' do
        registry_tool = Class.new do
          define_singleton_method(:tool_name) { 'registry_tool' }
          define_singleton_method(:description) { 'Registry tool' }
          define_singleton_method(:input_schema) { {} }
        end
        registry_mod = Module.new do
          define_singleton_method(:tools) { [registry_tool] }
          define_singleton_method(:deferred_tools) { [] }
        end
        stub_const('Legion::Tools::Registry', registry_mod)
        executor = described_class.new(request_with_tools)
        stub_req = double('request',
                          tools:  nil,
                          caller: nil,
                          id:     'req_test')
        executor.instance_variable_set(:@request, stub_req)
        expect(executor.send(:native_tool_definitions).map(&:name)).to include('registry_tool')
      end
    end
  end
end
