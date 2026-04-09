# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/tools/interceptor'
require 'legion/llm/tools/interceptors/python_venv'

RSpec.describe Legion::LLM::Tools::Interceptors::PythonVenv do
  let(:venv_dir) { described_class::VENV_DIR }

  describe '.match?' do
    it 'matches python tool names' do
      expect(described_class.match?('python')).to be true
      expect(described_class.match?('python3')).to be true
    end

    it 'matches pip tool names' do
      expect(described_class.match?('pip')).to be true
      expect(described_class.match?('pip3')).to be true
    end

    it 'does not match unrelated tools' do
      expect(described_class.match?('sh')).to be false
      expect(described_class.match?('ruby')).to be false
      expect(described_class.match?('grep')).to be false
    end
  end

  describe '.rewrite' do
    context 'when venv is available' do
      before do
        allow(described_class).to receive(:venv_available?).and_return(true)
      end

      it 'rewrites python3 to venv path' do
        result = described_class.rewrite(command: 'python3 script.py')
        expect(result[:command]).to eq("#{venv_dir}/bin/python3 script.py")
      end

      it 'rewrites pip3 to venv path' do
        result = described_class.rewrite(command: 'pip3 install pandas')
        expect(result[:command]).to eq("#{venv_dir}/bin/pip3 install pandas")
      end

      it 'rewrites standalone python3 (no args)' do
        result = described_class.rewrite(command: 'python3')
        expect(result[:command]).to eq("#{venv_dir}/bin/python3")
      end

      it 'does not rewrite non-python commands' do
        result = described_class.rewrite(command: 'ruby -e "puts 1"')
        expect(result[:command]).to eq('ruby -e "puts 1"')
      end

      it 'does not rewrite python3 mid-command' do
        result = described_class.rewrite(command: 'echo python3')
        expect(result[:command]).to eq('echo python3')
      end

      it 'preserves other args unchanged' do
        result = described_class.rewrite(command: 'python3 -c "print(1)"', cwd: '/tmp', timeout: 5000)
        expect(result[:cwd]).to eq('/tmp')
        expect(result[:timeout]).to eq(5000)
      end
    end

    context 'when venv is not available' do
      before do
        allow(described_class).to receive(:venv_available?).and_return(false)
      end

      it 'returns args unchanged' do
        result = described_class.rewrite(command: 'python3 script.py')
        expect(result[:command]).to eq('python3 script.py')
      end
    end

    context 'when command is not a string' do
      it 'returns args unchanged' do
        allow(described_class).to receive(:venv_available?).and_return(true)
        result = described_class.rewrite(command: nil)
        expect(result[:command]).to be_nil
      end
    end
  end

  describe '.register!' do
    after { Legion::LLM::Tools::Interceptor.reset! }

    it 'registers the python_venv interceptor' do
      described_class.register!
      expect(Legion::LLM::Tools::Interceptor.registered).to include(:python_venv)
    end

    it 'intercepts python tool calls end-to-end' do
      allow(described_class).to receive(:venv_available?).and_return(true)
      described_class.register!

      result = Legion::LLM::Tools::Interceptor.intercept('python', command: 'python3 hello.py')
      expect(result[:command]).to eq("#{venv_dir}/bin/python3 hello.py")
    end

    it 'passes through non-python tools' do
      allow(described_class).to receive(:venv_available?).and_return(true)
      described_class.register!

      result = Legion::LLM::Tools::Interceptor.intercept('sh', command: 'ls -la')
      expect(result[:command]).to eq('ls -la')
    end
  end
end
