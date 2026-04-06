# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::ToolAdapter do
  let(:simple_tool) do
    Class.new do
      define_singleton_method(:tool_name) { 'legion.query.knowledge' }
      define_singleton_method(:description) { 'Query the knowledge store' }
      define_singleton_method(:input_schema) { { type: 'object', properties: { query: { type: 'string' } } } }
      define_singleton_method(:call) { |**_args| 'result' }
    end
  end

  describe '#name' do
    it 'sanitizes dots to underscores' do
      adapter = described_class.new(simple_tool)
      expect(adapter.name).to eq('legion_query_knowledge')
    end

    it 'strips characters outside [a-zA-Z0-9_-]' do
      tool = Class.new do
        define_singleton_method(:tool_name) { 'my?tool!name' }
        define_singleton_method(:description) { '' }
      end
      adapter = described_class.new(tool)
      expect(adapter.name).to match(/\A[a-zA-Z0-9_-]+\z/)
    end

    it 'truncates names longer than 64 characters' do
      long_name = 'a' * 80
      tool = Class.new do
        define_singleton_method(:tool_name) { long_name }
        define_singleton_method(:description) { '' }
      end
      adapter = described_class.new(tool)
      expect(adapter.name.length).to be <= 64
    end

    it 'falls back to a non-empty name when sanitization yields an empty string' do
      tool = Class.new do
        define_singleton_method(:tool_name) { '???!!!' }
        define_singleton_method(:description) { '' }
      end
      adapter = described_class.new(tool)
      expect(adapter.name).not_to be_empty
      expect(adapter.name).to match(/\A[a-zA-Z0-9_-]+\z/)
    end

    it 'uses class name when tool_name is not defined' do
      tool = Class.new do
        define_singleton_method(:description) { '' }
      end
      adapter = described_class.new(tool)
      expect(adapter.name).not_to be_empty
    end
  end

  describe '#description' do
    it 'returns the tool description' do
      adapter = described_class.new(simple_tool)
      expect(adapter.description).to eq('Query the knowledge store')
    end

    it 'returns empty string when description is not defined' do
      tool = Class.new do
        define_singleton_method(:tool_name) { 'my_tool' }
      end
      adapter = described_class.new(tool)
      expect(adapter.description).to eq('')
    end
  end

  describe '#execute' do
    it 'delegates to the tool class and returns content' do
      result_tool = Class.new do
        define_singleton_method(:tool_name) { 'my_tool' }
        define_singleton_method(:description) { '' }
        define_singleton_method(:call) { |**_args| 'hello world' }
      end
      adapter = described_class.new(result_tool)
      expect(adapter.execute).to eq('hello world')
    end

    it 'returns error string on exception without re-raising' do
      failing_tool = Class.new do
        define_singleton_method(:tool_name) { 'bad_tool' }
        define_singleton_method(:description) { '' }
        define_singleton_method(:call) { |**_args| raise 'boom' }
      end
      adapter = described_class.new(failing_tool)
      result = adapter.execute
      expect(result).to include('Tool error:')
      expect(result).to include('boom')
    end
  end

  describe 'McpToolAdapter alias' do
    it 'is identical to ToolAdapter' do
      expect(Legion::LLM::Pipeline::McpToolAdapter).to equal(Legion::LLM::Pipeline::ToolAdapter)
    end
  end

  describe 'mcp_tool_adapter require shim' do
    it 'can be required by its legacy path without LoadError' do
      expect { require 'legion/llm/pipeline/mcp_tool_adapter' }.not_to raise_error
    end
  end
end
