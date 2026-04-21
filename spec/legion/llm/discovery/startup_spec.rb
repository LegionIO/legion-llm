# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/ollama'
require 'legion/llm/discovery/system'

RSpec.describe 'LLM startup discovery' do
  before do
    Legion::LLM::Discovery::Ollama.reset!
    Legion::LLM::Discovery::System.reset!
    allow(RubyLLM).to receive(:configure)
    allow(RubyLLM).to receive(:chat).and_return(double(ask: 'pong'))
    # Prevent actual embedding verification from making real network calls
    allow(Legion::LLM::Discovery).to receive(:verify_embedding).and_return(false)
    # Prevent auto-enabling of providers with unresolved env:// credentials
    allow(Legion::LLM::Call::Providers).to receive(:ollama_running?).and_return(false)
  end

  context 'when Ollama provider is enabled' do
    before do
      Legion::Settings[:llm][:providers][:ollama][:enabled] = true
      stub_request(:get, 'http://localhost:11434/api/tags')
        .to_return(status: 200, body: { 'models' => [{ 'name' => 'llama3:latest', 'size' => 4_000_000_000 }] }.to_json)
      allow(Legion::LLM::Discovery::System).to receive(:platform).and_return(:macos)
      allow(Legion::LLM::Discovery::System).to receive(:`).with('sysctl -n hw.memsize').and_return("68719476736\n")
      allow(Legion::LLM::Discovery::System).to receive(:`).with('vm_stat').and_return(
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:     500000.\nPages inactive:  300000.\n"
      )
    end

    it 'refreshes discovery caches during start' do
      expect(Legion::LLM::Discovery::Ollama).to receive(:refresh!).and_call_original
      expect(Legion::LLM::Discovery::System).to receive(:refresh!).and_call_original
      Legion::LLM.start
    end

    it 'logs discovered models' do
      allow(Legion::Logging).to receive(:info)
      expect(Legion::Logging).to receive(:info).with(/ollama model_count=1/).at_least(:once)
      Legion::LLM.start
    end
  end

  context 'when Ollama provider is disabled' do
    before do
      Legion::Settings[:llm][:providers][:ollama][:enabled] = false
      allow(Legion::LLM::Call::Providers).to receive(:ollama_running?).and_return(false)
    end

    it 'does not refresh discovery caches' do
      expect(Legion::LLM::Discovery::Ollama).not_to receive(:refresh!)
      Legion::LLM.start
    end
  end
end
