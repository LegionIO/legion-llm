# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor do
  let(:base_request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
    )
  end

  describe '#add_registry_tool_definitions (Settings::Extensions path)' do
    let(:tool_class_a) do
      Class.new do
        define_singleton_method(:call) { |**| { status: :success } }
      end
    end

    let(:tool_entries) do
      [
        {
          name:         'legion_read_file',
          description:  'Read a file',
          input_schema: { type: 'object', properties: { path: { type: 'string' } } },
          tool_class:   tool_class_a,
          extension:    'lex-node',
          runner:       'filesystem',
          deferred:     false
        },
        {
          name:         'legion_write_file',
          description:  'Write a file',
          input_schema: { type: 'object', properties: { path: { type: 'string' }, content: { type: 'string' } } },
          tool_class:   nil,
          extension:    'lex-node',
          runner:       'filesystem',
          deferred:     false
        }
      ]
    end

    let(:deferred_entries) do
      [
        {
          name:         'legion_heavy_compute',
          description:  'Heavy compute',
          input_schema: { type: 'object' },
          tool_class:   tool_class_a,
          extension:    'lex-compute',
          runner:       'compute',
          deferred:     true
        }
      ]
    end

    let(:extensions_mod) do
      all_entries = tool_entries + deferred_entries
      non_deferred = tool_entries
      deferred = deferred_entries
      Module.new do
        define_singleton_method(:tools) { all_entries }
        define_singleton_method(:filter_tools) do |**criteria|
          if criteria[:deferred] == false
            non_deferred
          elsif criteria[:deferred] == true
            deferred
          else
            all_entries
          end
        end
      end
    end

    it 'builds definitions from Settings::Extensions entries' do
      stub_const('Legion::Settings::Extensions', extensions_mod)

      executor = described_class.new(base_request)
      definitions = []
      executor.send(:add_registry_tool_definitions, definitions)

      expect(definitions.size).to eq(2)
      expect(definitions.map(&:name)).to contain_exactly('legion_read_file', 'legion_write_file')
    end

    it 'tracks tool_class in injected_tool_map' do
      stub_const('Legion::Settings::Extensions', extensions_mod)

      executor = described_class.new(base_request)
      definitions = []
      executor.send(:add_registry_tool_definitions, definitions)

      map = executor.instance_variable_get(:@injected_tool_map)
      expect(map['legion_read_file']).to eq(tool_class_a)
      # nil tool_class entries are not tracked
      expect(map).not_to have_key('legion_write_file')
    end

    it 'tracks source in native_tool_source_map' do
      stub_const('Legion::Settings::Extensions', extensions_mod)

      executor = described_class.new(base_request)
      definitions = []
      executor.send(:add_registry_tool_definitions, definitions)

      source_map = executor.instance_variable_get(:@native_tool_source_map)
      expect(source_map['legion_read_file'][:type]).to eq(:registry)
      expect(source_map['legion_read_file'][:extension]).to eq('lex-node')
    end

    it 'applies the local tool limit only to registry-added tools' do
      stub_const('Legion::Settings::Extensions', extensions_mod)
      Legion::Settings[:llm][:tool_trigger][:local_tool_limit] = 1
      client_tools = [
        Legion::LLM::Types::ToolDefinition.build(name: 'client_one', description: 'Client one'),
        Legion::LLM::Types::ToolDefinition.build(name: 'client_two', description: 'Client two')
      ]
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        tools:    client_tools,
        routing:  { provider: :vllm, model: 'qwen3.6-27b' }
      )
      executor = described_class.new(request)
      executor.instance_variable_set(:@resolved_provider, :vllm)

      names = executor.send(:native_tool_definitions).map(&:name)

      expect(names).to include('client_one', 'client_two', 'legion_read_file')
      expect(names).not_to include('legion_write_file')
    end
  end

  describe '#add_registry_tool_definitions when Settings::Extensions has no tools' do
    it 'does not add any tools' do
      allow(Legion::Settings::Extensions).to receive(:tools).and_return([])

      executor = described_class.new(base_request)
      definitions = []
      executor.send(:add_registry_tool_definitions, definitions)

      expect(definitions).to be_empty
    end

    it 'still adds trigger-matched tools' do
      triggered_tool = Class.new do
        define_singleton_method(:tool_name) { 'legion_dynamic_triggered' }
        define_singleton_method(:description) { 'Triggered dynamic tool' }
        define_singleton_method(:input_schema) { { type: 'object', properties: {} } }
      end
      allow(Legion::Settings::Extensions).to receive(:tools).and_return([])
      allow(Legion::Settings::Extensions).to receive(:filter_tools).and_return([])

      executor = described_class.new(base_request)
      executor.instance_variable_set(:@triggered_tools, [triggered_tool])
      definitions = []
      executor.send(:add_registry_tool_definitions, definitions)

      expect(definitions.map(&:name)).to contain_exactly('legion_dynamic_triggered')
      expect(executor.instance_variable_get(:@injected_tool_map)['legion_dynamic_triggered']).to eq(triggered_tool)
    end
  end
end
