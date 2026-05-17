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
    before do
      allow(Legion::LLM::Tools::Special).to receive(:python_available?).and_return(false)
      allow(Legion::LLM::Tools::Special).to receive(:ruby_path).and_return('/usr/bin/ruby')
    end

    it 'pins the Legion special tool inventory before all other tools' do
      extensions_mod = Module.new do
        define_singleton_method(:tools) do
          [{ name: 'registry_tool', description: 'Registry tool', input_schema: {}, deferred: false }]
        end
        define_singleton_method(:filter_tools) do |**criteria|
          criteria[:deferred] == false ? tools : []
        end
      end
      stub_const('Legion::Settings::Extensions', extensions_mod)

      executor = described_class.new(request_with_tools)
      names = executor.send(:native_tool_definitions).map(&:name)

      expect(names.first).to eq(Legion::LLM::Tools::Special::LIST_SPECIAL_TOOLS_NAME)
      expect(names.index('ruby')).to be < names.index('my_tool')
      expect(names.index('my_tool')).to be < names.index('registry_tool')
    end

    it 'injects python and pip defaults when Legion Python is available' do
      allow(Legion::LLM::Tools::Special).to receive(:python_available?).and_return(true)
      allow(Legion::LLM::Tools::Special).to receive(:python_path).and_return('/legion/python/bin/python3')
      allow(Legion::LLM::Tools::Special).to receive(:pip_path).and_return('/legion/python/bin/pip')

      executor = described_class.new(request_empty_tools)
      names = executor.send(:native_tool_definitions).map(&:name)

      expect(names).to include('python', 'pip')
    end

    context 'when @request.tools is a non-empty array' do
      it 'includes request tools as native definitions' do
        executor = described_class.new(request_with_tools)
        expect(executor.send(:native_tool_definitions).map(&:name)).to include('my_tool')
      end

      it 'skips non-executable client tools unless passthrough is explicitly enabled' do
        client_tool = Legion::LLM::Types::ToolDefinition.build(
          name:        'client_shell',
          description: 'Client shell',
          source:      { type: :client, executable: false }
        )
        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'use client shell' }],
          tools:    [client_tool],
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
        )

        executor = described_class.new(request)

        expect(executor.send(:native_tool_definitions).map(&:name)).not_to include('client_shell')
      end

      it 'includes non-executable client tools when passthrough is explicitly enabled' do
        client_tool = Legion::LLM::Types::ToolDefinition.build(
          name:        'client_shell',
          description: 'Client shell',
          source:      { type: :client, executable: false }
        )
        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'use client shell' }],
          tools:    [client_tool],
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
          metadata: { client_tool_passthrough: true }
        )

        executor = described_class.new(request)

        expect(executor.send(:native_tool_definitions).map(&:name)).to include('client_shell')
      end
    end

    context 'when @request.tools is an empty array []' do
      it 'adds registry tools in addition to the empty client list' do
        extensions_mod = Module.new do
          define_singleton_method(:tools) do
            [{ name: 'registry_tool', description: 'Registry tool', input_schema: {}, deferred: false }]
          end
          define_singleton_method(:filter_tools) do |**criteria|
            criteria[:deferred] == false ? tools : []
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)

        executor = described_class.new(request_empty_tools)
        expect(executor.send(:native_tool_definitions).map(&:name)).to include('registry_tool')
      end

      it 'injects requested deferred registry tools from metadata' do
        extensions_mod = Module.new do
          define_singleton_method(:tools) do
            [{ name: 'registry_tool', description: 'Registry tool', input_schema: {}, deferred: true }]
          end
          define_singleton_method(:filter_tools) do |**criteria|
            criteria[:deferred] == true ? tools : []
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)
        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'use registry tool' }],
          tools:    [],
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
          metadata: { requested_tools: ['registry_tool'] }
        )

        executor = described_class.new(request)

        expect(executor.send(:native_tool_definitions).map(&:name)).to include('registry_tool')
      end
    end

    context 'when @request.tools is a non-Array (nil via direct construction)' do
      it 'adds Settings::Extensions tools' do
        extensions_mod = Module.new do
          define_singleton_method(:tools) do
            [{ name: 'registry_tool', description: 'Registry tool', input_schema: {}, deferred: false }]
          end
          define_singleton_method(:filter_tools) do |**criteria|
            criteria[:deferred] == false ? tools : []
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)

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
