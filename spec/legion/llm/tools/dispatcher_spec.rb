# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Tools::Dispatcher do
  describe '.check_registry_override' do
    context 'when Legion::Settings::Extensions is defined with find_tool' do
      let(:extensions_mod) do
        Module.new do
          define_singleton_method(:find_tool) do |name|
            case name
            when 'legion_read_file'
              {
                name:       'legion_read_file',
                tool_class: Class.new { define_singleton_method(:call) { |**| { status: :success } } },
                extension:  'lex-node',
                runner:     'filesystem',
                function:   'read'
              }
            when 'legion_deploy'
              {
                name:      'legion_deploy',
                extension: 'lex-deploy',
                runner:    'release',
                function:  'deploy'
              }
            end
          end
        end
      end

      it 'returns a registry source when tool_class is present' do
        stub_const('Legion::Settings::Extensions', extensions_mod)
        result = described_class.check_registry_override('legion_read_file')
        expect(result[:type]).to eq(:registry)
        expect(result[:tool_class]).to respond_to(:call)
      end

      it 'returns an extension source when tool_class is absent' do
        stub_const('Legion::Settings::Extensions', extensions_mod)
        result = described_class.check_registry_override('legion_deploy')
        expect(result[:type]).to eq(:extension)
        expect(result[:lex]).to eq('lex-deploy')
        expect(result[:runner]).to eq('release')
        expect(result[:function]).to eq('deploy')
      end

      it 'returns nil when the tool is not found' do
        stub_const('Legion::Settings::Extensions', extensions_mod)
        result = described_class.check_registry_override('nonexistent')
        expect(result).to be_nil
      end
    end

    context 'when Legion::Settings::Extensions has no matching tool' do
      it 'returns nil' do
        allow(Legion::Settings::Extensions).to receive(:find_tool).with('any_tool').and_return(nil)
        result = described_class.check_registry_override('any_tool')
        expect(result).to be_nil
      end
    end
  end

  describe '.check_override' do
    it 'prefers explicit settings override over registry and catalog overrides' do
      extensions_mod = Module.new do
        define_singleton_method(:find_tool) do |_name|
          { name: 'test_tool', tool_class: Class.new { define_singleton_method(:call) { |**| {} } } }
        end
      end
      stub_const('Legion::Settings::Extensions', extensions_mod)

      settings_result = { type: :extension, lex: 'lex-other', runner: 'r', function: 'f' }
      allow(described_class).to receive(:check_settings_override).and_return(
        settings_result
      )

      result = described_class.check_override('test_tool')
      expect(result).to eq(settings_result)
    end

    it 'falls back to settings override when registry returns nil' do
      extensions_mod = Module.new do
        define_singleton_method(:find_tool) { |_name| nil }
      end
      stub_const('Legion::Settings::Extensions', extensions_mod)

      settings_result = { type: :extension, lex: 'lex-other', runner: 'r', function: 'f' }
      allow(described_class).to receive(:check_settings_override).and_return(settings_result)
      allow(described_class).to receive(:check_catalog_override).and_return(nil)

      result = described_class.check_override('test_tool')
      expect(result).to eq(settings_result)
    end
  end
end
