# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/ollama'
require 'legion/llm/discovery/system'

RSpec.describe 'LLM startup discovery' do
  before do
    Legion::LLM::Discovery::Ollama.reset!
    Legion::LLM::Discovery::System.reset!
    Legion::LLM::Discovery::Vllm.reset! if defined?(Legion::LLM::Discovery::Vllm)
    # Prevent actual embedding verification from making real network calls
    allow(Legion::LLM::Discovery).to receive(:verify_embedding).and_return(false)
    # Prevent auto-enabling of providers with unresolved env:// credentials
    allow(Legion::LLM::Call::Providers).to receive(:ollama_running?).and_return(false)
    allow(Legion::LLM::Call::Providers).to receive(:vllm_running?).and_return(false)
    # Stub HTTP endpoints so discovered_instances doesn't trigger real calls
    stub_request(:get, 'http://localhost:11434/api/tags')
      .to_return(status: 200, body: { 'models' => [] }.to_json)
    stub_request(:get, 'http://localhost:8000/v1/models')
      .to_return(status: 200, body: { 'data' => [] }.to_json)
    stub_request(:post, %r{/api/show}).to_return(status: 404)
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
      expect(Legion::LLM::Discovery::Ollama).to receive(:refresh!).at_least(:once).and_call_original
      expect(Legion::LLM::Discovery::System).to receive(:refresh!).at_least(:once).and_call_original
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

  describe 'boot wiring: Router.populate_auto_rules' do
    before do
      Legion::LLM::Router.reset!
      Legion::Settings[:llm][:providers][:ollama][:enabled] = false
      allow(Legion::LLM::Call::Providers).to receive(:ollama_running?).and_return(false)
      allow(Legion::LLM::Call::Providers).to receive(:vllm_running?).and_return(false)
    end

    it 'populates auto_rules during start so routing is ready' do
      expect(Legion::LLM::Router.auto_rules_populated?).to be false
      Legion::LLM.start
      expect(Legion::LLM::Router.auto_rules_populated?).to be true
    end

    it 'calls Router.populate_auto_rules with Discovery.discovered_instances' do
      expect(Legion::LLM::Router).to receive(:populate_auto_rules).with(kind_of(Hash)).and_call_original
      Legion::LLM.start
    end
  end
end
