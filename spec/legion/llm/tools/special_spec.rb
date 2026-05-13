# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Tools::Special do
  before do
    described_class.reset_runtime_cache!
    allow(described_class).to receive(:ruby_path).and_return('/usr/bin/ruby')
  end

  describe '.pinned_definitions' do
    it 'places the inventory tool first' do
      allow(described_class).to receive(:python_available?).and_return(false)

      definitions = described_class.pinned_definitions

      expect(definitions.first.name).to eq(described_class::LIST_SPECIAL_TOOLS_NAME)
      expect(definitions.map(&:name)).to include('ruby')
    end

    it 'adds python and pip when a Legion Python environment is available' do
      allow(described_class).to receive(:python_available?).and_return(true)
      allow(described_class).to receive(:python_path).and_return('/legion/python/bin/python3')
      allow(described_class).to receive(:pip_path).and_return('/legion/python/bin/pip')

      names = described_class.pinned_definitions.map(&:name)

      expect(names).to include('python', 'pip')
    end
  end

  describe '.ruby_path' do
    before do
      allow(described_class).to receive(:ruby_path).and_call_original
    end

    it 'prefers a LegionIO packaged process ruby over PATH ruby' do
      allow(described_class).to receive(:process_ruby_path)
        .and_return('/opt/homebrew/Cellar/legionio/1.9.29-1/libexec/bin/ruby')
      allow(described_class).to receive(:path_ruby).and_return('/Users/test/.rbenv/shims/ruby')
      allow(described_class).to receive(:executable_file?)
        .with('/opt/homebrew/Cellar/legionio/1.9.29-1/libexec/bin/ruby')
        .and_return(true)

      expect(described_class.ruby_path).to eq('/opt/homebrew/Cellar/legionio/1.9.29-1/libexec/bin/ruby')
    end

    it 'uses PATH ruby for non-packaged runtimes' do
      allow(described_class).to receive(:process_ruby_path).and_return('/Users/test/.rbenv/versions/4.0.2/bin/ruby')
      allow(described_class).to receive(:path_ruby).and_return('/Users/test/.rbenv/shims/ruby')

      expect(described_class.ruby_path).to eq('/Users/test/.rbenv/shims/ruby')
    end
  end

  describe '.inventory' do
    it 'returns special tools, runtime details, and Settings::Extensions tools' do
      extensions_mod = Module.new do
        define_singleton_method(:tools) do
          [
            {
              name:          'legion_read_file',
              description:   'Read a file',
              input_schema:  { type: 'object', properties: { path: { type: 'string' } } },
              extension:     'lex-node',
              runner:        'filesystem',
              function:      'read',
              trigger_words: %w[file read],
              deferred:      true
            }
          ]
        end
      end
      stub_const('Legion::Settings::Extensions', extensions_mod)
      allow(described_class).to receive(:python_available?).and_return(false)

      inventory = described_class.inventory

      expect(inventory[:special_tools].first[:name]).to eq(described_class::LIST_SPECIAL_TOOLS_NAME)
      expect(inventory[:runtime][:ruby][:path]).to eq('/usr/bin/ruby')
      expect(inventory[:settings_extensions_tools]).to contain_exactly(
        hash_including(name: 'legion_read_file', deferred: true, extension: 'lex-node')
      )
    end
  end

  describe '.dispatch' do
    it 'returns inventory JSON for the pinned list tool' do
      allow(described_class).to receive(:inventory).and_return(special_tools: [], settings_extensions_tools: [])

      result = described_class.dispatch(described_class::LIST_SPECIAL_TOOLS_NAME)

      expect(result[:status]).to eq(:success)
      expect(Legion::JSON.load(result[:result])).to include(special_tools: [])
    end

    it 'executes runtime code through the requested executable' do
      status = instance_double(Process::Status, success?: true, exitstatus: 0)
      allow(described_class).to receive(:executable_file?).with('/usr/bin/ruby').and_return(true)
      allow(described_class).to receive(:run_process)
        .with('/usr/bin/ruby', ['-e', 'puts 1'], code: 'puts 1')
        .and_return(["1\n", status])

      result = described_class.dispatch('ruby', code: 'puts 1')

      expect(result[:status]).to eq(:success)
      expect(result[:result]).to include('exit=0', "1\n")
    end
  end
end
