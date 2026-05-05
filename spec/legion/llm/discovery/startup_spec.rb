# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/discovery/system'

RSpec.describe 'LLM startup discovery' do
  before do
    Legion::LLM::Discovery.reset!
    Legion::LLM::Discovery::System.reset!
    # Prevent actual embedding verification from making real network calls
    allow(Legion::LLM::Discovery).to receive(:verify_embedding).and_return(false)
  end

  context 'when providers are registered in the Registry' do
    before do
      allow(Legion::LLM::Discovery::System).to receive(:platform).and_return(:macos)
      allow(Legion::LLM::Discovery::System).to receive(:`).with('sysctl -n hw.memsize').and_return("68719476736\n")
      allow(Legion::LLM::Discovery::System).to receive(:`).with('vm_stat').and_return(
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:     500000.\nPages inactive:  300000.\n"
      )
    end

    it 'refreshes discovery caches during start' do
      expect(Legion::LLM::Discovery).to receive(:run).at_least(:once).and_call_original
      expect(Legion::LLM::Discovery::System).to receive(:refresh!).at_least(:once).and_call_original
      Legion::LLM.start
    end
  end

  describe 'boot wiring: Router.populate_auto_rules' do
    before do
      Legion::LLM::Router.reset!
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
