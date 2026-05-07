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

  describe '#dispatch_client_tool' do
    it 'reads text files as UTF-8 content' do
      Tempfile.create(['legion-text', '.txt']) do |file|
        file.write('hello')
        file.close

        expect(host.send(:dispatch_client_tool, 'file_read', path: file.path)).to eq('hello')
      end
    end

    it 'rejects non-PDF binary files' do
      Tempfile.create(['legion-binary', '.bin']) do |file|
        file.binmode
        file.write("abc\x00def")
        file.close

        expect(host.send(:dispatch_client_tool, 'file_read', path: file.path)).to eq('Binary file detected, cannot read as text.')
      end
    end

    it 'extracts PDF text through pdf-reader' do
      page = double('page', text: 'extracted text')
      reader_class = Class.new do
        define_method(:initialize) { |path| @path = path }
      end
      allow(reader_class).to receive(:new).and_return(double('reader', pages: [page]))
      stub_const('PDF', Module.new)
      stub_const('PDF::Reader', reader_class)

      Tempfile.create(['legion-doc', '.pdf']) do |file|
        file.binmode
        file.write('%PDF-1.7')
        file.close

        expect(host.send(:dispatch_client_tool, 'file_read', path: file.path)).to eq('extracted text')
      end
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
