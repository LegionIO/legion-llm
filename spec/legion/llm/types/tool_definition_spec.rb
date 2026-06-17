# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Types::ToolDefinition do
  describe '.build' do
    it 'creates a definition with name, description, parameters, and source' do
      td = described_class.build(name: 'test_tool', description: 'A test', parameters: { type: 'object' })
      expect(td.name).to eq('test_tool')
      expect(td.description).to eq('A test')
      expect(td.parameters).to eq({ type: 'object' })
      expect(td.source).to eq({ type: :builtin })
    end

    it 'normalizes parameters at construction — injects type when missing' do
      td = described_class.build(name:       'multi_agent_v1',
                                 parameters: { properties: { task: { type: 'string' } } })
      expect(td.parameters[:type]).to eq('object')
      expect(td.parameters[:properties]).to eq(task: { type: 'string' })
    end

    it 'normalizes nil parameters to empty object schema' do
      td = described_class.build(name: 'bare_tool')
      expect(td.parameters).to eq(type: 'object', properties: {})
    end

    it 'wraps a bare property map under type:object/properties' do
      td = described_class.build(name:       'location_tool',
                                 parameters: { location: { type: 'string' } })
      expect(td.parameters).to eq(type: 'object', properties: { location: { type: 'string' } })
    end

    it 'passes explicit-type schemas through unchanged' do
      schema = { type: 'object', properties: { a: { type: 'string' } } }
      td = described_class.build(name: 'typed', parameters: schema)
      expect(td.parameters).to eq(schema)
    end

    it 'leaves composite schemas without forcing type' do
      schema = { oneOf: [{ type: 'string' }, { type: 'integer' }] }
      td = described_class.build(name: 'composite', parameters: schema)
      expect(td.parameters).to eq(schema)
    end
  end

  describe '.from_registry_entry' do
    let(:entry) do
      {
        name:         'legion_read_file',
        description:  'Read a file from disk',
        input_schema: { type: 'object', properties: { path: { type: 'string' } } },
        tool_class:   dummy_tool_class,
        extension:    'lex-node',
        runner:       'filesystem'
      }
    end

    let(:dummy_tool_class) do
      Class.new do
        define_singleton_method(:call) { |**_args| { status: :success } }
      end
    end

    it 'builds from a registry entry hash' do
      td = described_class.from_registry_entry(entry)
      expect(td.name).to eq('legion_read_file')
      expect(td.description).to eq('Read a file from disk')
      expect(td.parameters).to eq({ type: 'object', properties: { path: { type: 'string' } } })
      expect(td.source[:type]).to eq(:registry)
      expect(td.source[:tool_class]).to eq(dummy_tool_class)
      expect(td.source[:extension]).to eq('lex-node')
      expect(td.source[:runner]).to eq('filesystem')
    end

    it 'falls back to :parameters when :input_schema is absent' do
      entry_without_schema = entry.dup
      entry_without_schema.delete(:input_schema)
      entry_without_schema[:parameters] = { type: 'object', properties: { file: { type: 'string' } } }

      td = described_class.from_registry_entry(entry_without_schema)
      expect(td.parameters).to eq({ type: 'object', properties: { file: { type: 'string' } } })
    end

    it 'handles entries without tool_class' do
      entry_no_class = entry.dup
      entry_no_class.delete(:tool_class)

      td = described_class.from_registry_entry(entry_no_class)
      expect(td.source[:tool_class]).to be_nil
      expect(td.source[:extension]).to eq('lex-node')
    end

    it 'sanitizes tool names with dots' do
      dotted = entry.merge(name: 'legion.read_file')
      td = described_class.from_registry_entry(dotted)
      expect(td.name).to eq('legion_read_file')
    end
  end
end
