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

      it 'skips non-executable client tools when passthrough is explicitly disabled' do
        client_tool = Legion::LLM::Types::ToolDefinition.build(
          name:        'client_shell',
          description: 'Client shell',
          source:      { type: :client, executable: false }
        )
        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'use client shell' }],
          tools:    [client_tool],
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
          metadata: { client_tool_passthrough: false }
        )

        executor = described_class.new(request)

        expect(executor.send(:native_tool_definitions).map(&:name)).not_to include('client_shell')
      end

      it 'passes through non-executable client tools by default' do
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

        expect(executor.send(:native_tool_definitions).map(&:name)).to include('client_shell')
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

      it 'includes non-executable client tools when the setting is enabled' do
        Legion::Settings[:llm][:tool_trigger][:client_tool_passthrough] = true
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

        expect(executor.send(:native_tool_definitions).map(&:name)).to include('client_shell')
      end

      it 'still injects registry tools when client and server tools are mixed' do
        extensions_mod = Module.new do
          define_singleton_method(:tools) do
            [{ name: 'registry_tool', description: 'Registry tool', input_schema: {}, deferred: false }]
          end
          define_singleton_method(:filter_tools) do |**criteria|
            criteria[:deferred] == false ? tools : []
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)

        client_tool = Legion::LLM::Types::ToolDefinition.build(
          name:        'client_shell',
          description: 'Client shell',
          source:      { type: :client, executable: false }
        )
        server_tool = Legion::LLM::Types::ToolDefinition.build(
          name:        'registry_style_tool',
          description: 'Server style tool',
          source:      { type: :extension, extension: 'sample_extension', runner: 'tools' }
        )
        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'mixed tools' }],
          tools:    [client_tool, server_tool],
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
        )

        executor = described_class.new(request)

        names = executor.send(:native_tool_definitions).map(&:name)
        expect(names).to include('client_shell', 'registry_style_tool', 'registry_tool')
      end

      it 'resolves registry-backed tool definitions even when source says non-executable client' do
        resolved_tool_class = Class.new do
          def self.call(*); end
        end

        extensions_mod = Module.new do
          define_singleton_method(:tools) { [] }
          define_singleton_method(:filter_tools) { [] }
          define_singleton_method(:find_tool) do |name|
            return nil unless name.to_s == 'registry_lookup'

            {
              name:         'registry_lookup',
              description:  'Registry lookup',
              input_schema: {},
              tool_class:   resolved_tool_class
            }
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)

        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'lookup from registry' }],
          tools:    [{ name: 'registry_lookup', description: 'Registry lookup', parameters: {}, source: { type: :client, executable: false } }],
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
        )

        executor = described_class.new(request)
        definitions = executor.send(:native_tool_definitions)
        lookup = definitions.find { |definition| definition.name == 'registry_lookup' }

        expect(lookup.source[:type]).to eq(:registry)
        expect(lookup.source[:tool_class]).to eq(resolved_tool_class)
        expect(executor.send(:client_tools_only?)).to be(false)
      end

      it 'resolves sanitized LegionIO client-shaped tools back to dotted registry tools' do
        extensions_mod = Module.new do
          define_singleton_method(:tools) { [] }
          define_singleton_method(:filter_tools) { [] }
          define_singleton_method(:find_tool) do |name|
            return nil unless name.to_s == 'legion.microsoft_teams_create_chain'

            {
              name:         'legion.microsoft_teams_create_chain',
              description:  'Create a Teams chain',
              input_schema: {},
              extension:    'lex-microsoft_teams',
              runner:       'chains',
              function:     'create_chain'
            }
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)

        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'create a chain' }],
          tools:    [{
            name:        'legion_microsoft_teams_create_chain',
            description: 'Create a Teams chain',
            parameters:  {},
            source:      { type: :client, executable: false, raw_name: 'legion.microsoft_teams_create_chain' }
          }],
          routing:  { provider: :vllm, model: 'qwen3.6-27b' },
          metadata: { client_tool_passthrough: true }
        )

        executor = described_class.new(request)
        definitions = executor.send(:native_tool_definitions)
        tool = definitions.find { |definition| definition.name == 'legion_microsoft_teams_create_chain' }

        expect(tool.source).to include(type: :extension, lex: 'lex-microsoft_teams', runner: 'chains', function: 'create_chain')
        expect(executor.send(:client_tools_only?)).to be(false)
      end

      it 'keeps explicit all-client tool requests as passthrough-only' do
        extensions_mod = Module.new do
          define_singleton_method(:tools) { [] }
          define_singleton_method(:filter_tools) { [] }
          define_singleton_method(:find_tool) { |_name| nil }
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)

        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'no registry tool' }],
          tools:    [{ name: 'local_client_only', description: 'Client tool', parameters: {}, source: { type: :client, executable: false } }],
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
          metadata: { client_tool_passthrough: true }
        )

        executor = described_class.new(request)
        expect(executor.send(:client_tools_only?)).to be(true)
      end

      it 'does not inject registry tools for all-client tool calls when passthrough is enabled' do
        extensions_mod = Module.new do
          define_singleton_method(:tools) do
            [{ name: 'registry_tool', description: 'Registry tool', input_schema: {}, deferred: false }]
          end
          define_singleton_method(:filter_tools) { |**| [] }
          define_singleton_method(:find_tool) { |**_| nil }
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)

        client_tool = Legion::LLM::Types::ToolDefinition.build(
          name:        'client_shell',
          description: 'Client shell',
          source:      { type: :client, executable: false }
        )
        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'client-only tools' }],
          tools:    [client_tool],
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
          metadata: { client_tool_passthrough: true }
        )

        executor = described_class.new(request)
        names = executor.send(:native_tool_definitions).map(&:name)

        expect(names).to include('client_shell')
        expect(names).not_to include('registry_tool')
      end

      it 'filters explicitly enabled passthrough client tools with the default blacklist' do
        tools = ['sudo', 'git', 'ls', 'grep', 'legion', 'legionio', 'legionio do', 'legionio/legion',
                 'legionio_do', 'computer_use_session', 'plugin__aithena__recall',
                 'plugin__cron__run_now'].map do |name|
          Legion::LLM::Types::ToolDefinition.build(
            name:        name,
            description: "#{name} client tool",
            source:      { type: :client, executable: false }
          )
        end
        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'use client tools' }],
          tools:    tools,
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
          metadata: { client_tool_passthrough: true }
        )

        executor = described_class.new(request)
        names = executor.send(:native_tool_definitions).map(&:name)

        expect(names).to include('git', 'ls', 'grep')
        expect(names).not_to include(
          'sudo', 'legion', 'legionio', 'legioniodo', 'legioniolegion', 'legionio_do',
          'computer_use_session', 'plugin__aithena__recall', 'plugin__cron__run_now'
        )
      end

      it 'filters passthrough client tools with an explicit whitelist' do
        Legion::Settings[:llm][:tool_trigger][:client_tool_passthrough_whitelist] = %w[git grep]
        Legion::Settings[:llm][:tool_trigger][:client_tool_passthrough_blacklist] = []
        tools = %w[git ls grep].map do |name|
          Legion::LLM::Types::ToolDefinition.build(
            name:        name,
            description: "#{name} client tool",
            source:      { type: :client, executable: false }
          )
        end
        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'use client tools' }],
          tools:    tools,
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
          metadata: { client_tool_passthrough: true }
        )

        executor = described_class.new(request)
        names = executor.send(:native_tool_definitions).map(&:name)

        expect(names).to include('git', 'grep')
        expect(names).not_to include('ls')
      end

      it 'lets the blacklist win over the whitelist for passthrough client tools' do
        Legion::Settings[:llm][:tool_trigger][:client_tool_passthrough_whitelist] = %w[git sudo]
        Legion::Settings[:llm][:tool_trigger][:client_tool_passthrough_blacklist] = %w[sudo]
        tools = %w[git sudo].map do |name|
          Legion::LLM::Types::ToolDefinition.build(
            name:        name,
            description: "#{name} client tool",
            source:      { type: :client, executable: false }
          )
        end
        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'use client tools' }],
          tools:    tools,
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
          metadata: { client_tool_passthrough: true }
        )

        executor = described_class.new(request)
        names = executor.send(:native_tool_definitions).map(&:name)

        expect(names).to include('git')
        expect(names).not_to include('sudo')
      end

      it 'deduplicates client Python binary aliases against native special Python tools' do
        allow(Legion::LLM::Tools::Special).to receive(:python_available?).and_return(true)
        allow(Legion::LLM::Tools::Special).to receive(:python_path).and_return('/legion/python/bin/python3')
        allow(Legion::LLM::Tools::Special).to receive(:pip_path).and_return('/legion/python/bin/pip3')
        tools = %w[python3 pip3].map do |name|
          Legion::LLM::Types::ToolDefinition.build(
            name:        name,
            description: "#{name} client tool",
            source:      { type: :client, executable: false }
          )
        end
        request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'use python tools' }],
          tools:    tools,
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
          metadata: { client_tool_passthrough: true }
        )

        executor = described_class.new(request)
        names = executor.send(:native_tool_definitions).map(&:name)

        expect(names).to include('python', 'pip')
        expect(names).not_to include('python3', 'pip3')
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
