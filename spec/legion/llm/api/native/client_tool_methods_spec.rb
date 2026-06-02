# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'legion/llm/api/native/helpers'

RSpec.describe Legion::LLM::API::Native::ClientToolMethods do
  let(:host) do
    Class.new do
      include Legion::LLM::API::Native::ClientToolMethods
    end.new
  end

  let(:tmp_dir) { File.join(Dir.pwd, 'tmp', 'test_client_tools') }

  before { FileUtils.mkdir_p(tmp_dir) }
  after { FileUtils.rm_rf(tmp_dir) }

  describe '#dispatch_client_tool' do
    it 'reads text files as UTF-8 content' do
      path = File.join(tmp_dir, 'text.txt')
      File.write(path, 'hello')

      expect(host.send(:dispatch_client_tool, 'file_read', path: path)).to eq('hello')
    end

    it 'rejects non-PDF binary files' do
      path = File.join(tmp_dir, 'binary.bin')
      File.binwrite(path, "abc\x00def")

      expect(host.send(:dispatch_client_tool, 'file_read', path: path)).to eq('Binary file detected, cannot read as text.')
    end

    it 'extracts PDF text through pdf-reader' do
      page = double('page', text: 'extracted text')
      reader_class = Class.new do
        define_method(:initialize) { |path| @path = path }
      end
      allow(reader_class).to receive(:new).and_return(double('reader', pages: [page]))
      stub_const('PDF', Module.new)
      stub_const('PDF::Reader', reader_class)

      path = File.join(tmp_dir, 'doc.pdf')
      File.binwrite(path, '%PDF-1.7')

      expect(host.send(:dispatch_client_tool, 'file_read', path: path)).to eq('extracted text')
    end
  end
end

RSpec.describe Legion::LLM::API::Native::Helpers do
  describe '#build_client_tool_class' do
    let(:app_class) do
      Class.new do
        def self.helpers(&)
          class_eval(&)
        end
      end
    end

    before do
      described_class.registered(app_class)
    end

    it 'marks API-submitted client tools as non-executable server-side' do
      tool = app_class.new.send(:build_client_tool_class, 'file_write', 'write file', {})

      expect(tool.source).to include(type: :client, executable: false)
    end
  end
end
