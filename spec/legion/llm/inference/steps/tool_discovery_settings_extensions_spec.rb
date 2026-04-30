# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::ToolDiscovery do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'discover tools' }],
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
    )
  end

  let(:executor) { Legion::LLM::Inference::Executor.new(request) }

  describe '#discover_registry_tools' do
    context 'when Settings::Extensions is available with tools' do
      let(:tool_entries) do
        [
          {
            name:         'legion_status_check',
            description:  'Check system status',
            input_schema: { type: 'object' },
            deferred:     false
          }
        ]
      end

      let(:extensions_mod) do
        entries = tool_entries
        Module.new do
          define_singleton_method(:tools) { entries }
          define_singleton_method(:filter_tools) do |**criteria|
            criteria[:deferred] == false ? entries : []
          end
        end
      end

      it 'discovers tools from Settings::Extensions' do
        stub_const('Legion::Settings::Extensions', extensions_mod)

        executor.send(:discover_registry_tools)
        discovered = executor.instance_variable_get(:@discovered_tools)

        expect(discovered.size).to eq(1)
        expect(discovered.first[:name]).to eq('legion_status_check')
        expect(discovered.first[:source][:type]).to eq(:registry)
      end
    end

    context 'when Settings::Extensions is not available' do
      it 'falls back to Legion::Tools::Registry' do
        hide_const('Legion::Settings::Extensions') if defined?(Legion::Settings::Extensions)

        registry_tool = Class.new do
          define_singleton_method(:tool_name) { 'legacy_discover_tool' }
          define_singleton_method(:description) { 'Legacy' }
          define_singleton_method(:input_schema) { {} }
        end
        registry_mod = Module.new do
          define_singleton_method(:tools) { [registry_tool] }
        end
        stub_const('Legion::Tools::Registry', registry_mod)

        executor.send(:discover_registry_tools)
        discovered = executor.instance_variable_get(:@discovered_tools)

        expect(discovered.size).to eq(1)
        expect(discovered.first[:name]).to eq('legacy_discover_tool')
      end
    end

    context 'when neither registry is available' do
      it 'does not discover any tools' do
        hide_const('Legion::Settings::Extensions') if defined?(Legion::Settings::Extensions)
        hide_const('Legion::Tools::Registry') if defined?(Legion::Tools::Registry)

        executor.send(:discover_registry_tools)
        discovered = executor.instance_variable_get(:@discovered_tools)

        expect(discovered).to be_empty
      end
    end
  end
end
