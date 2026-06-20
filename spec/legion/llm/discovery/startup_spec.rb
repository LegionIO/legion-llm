# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inventory/discovery/system'

RSpec.describe 'LLM startup discovery' do
  before do
    Legion::LLM::Inventory::Discovery.reset!
    Legion::LLM::Inventory::Discovery::System.reset!
    allow(Legion::LLM::Inventory::Discovery).to receive(:verify_embedding).and_return(false)
  end

  context 'when providers are registered in the Registry' do
    before do
      allow(Legion::LLM::Inventory::Discovery::System).to receive(:platform).and_return(:macos)
      allow(Legion::LLM::Inventory::Discovery::System).to receive(:`).with('sysctl -n hw.memsize').and_return("68719476736\n")
      allow(Legion::LLM::Inventory::Discovery::System).to receive(:`).with('vm_stat').and_return(
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:     500000.\nPages inactive:  300000.\n"
      )
    end

    it 'refreshes discovery caches during start' do
      expect(Legion::LLM::Inventory::Discovery).to receive(:run).at_least(:once).and_call_original
      expect(Legion::LLM::Inventory::Discovery::System).to receive(:refresh!).at_least(:once).and_call_original
      Legion::LLM.start
    end
  end

  describe 'boot wiring: Inventory observers' do
    it 'attaches the SettingsObserver' do
      expect(Legion::LLM::Inventory::SettingsObserver).to receive(:attach!).and_call_original
      Legion::LLM.start
    end

    it 'does NOT call Router.populate_auto_rules from Legion::LLM.start' do
      # G8 / cyber-Medium: internal caller deleted in P4; external lex-llm-* callers still
      # go through the no-op stub via their own respond_to? guards.
      expect(Legion::LLM::Router).not_to receive(:populate_auto_rules)
      Legion::LLM.start
    end
  end
end
