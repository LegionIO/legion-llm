# frozen_string_literal: true

require 'spec_helper'
require 'legion/settings/extensions'

RSpec.describe 'Trigger matching preserves the shared tool inventory' do
  let(:matcher) do
    Class.new do
      include Legion::Logging::Helper
      include Legion::LLM::Inference::Steps::TriggerMatch
    end.new
  end
  let(:tool_name) { 'legion-regression-inventory-list' }

  before do
    Legion::Settings::Extensions.register_tool(
      tool_name,
      extension: 'lex-regression', runner: 'inventory', function: 'list',
      trigger_words: %w[inventory tools], deferred: true
    )
  end

  after do
    Legion::Settings::Extensions.unregister_tool(tool_name)
  end

  it 'keeps registry data and server-tool output identical across repeated requests' do
    original = Legion::JSON.dump(Legion::Settings::Extensions.find_tool(tool_name))
    inventory = Legion::JSON.dump(Legion::LLM::Tools::Special.inventory)

    40.times do
      entry = Legion::Settings::Extensions.find_tool(tool_name)
      words = matcher.send(:trigger_words_for_entry, entry)
      expect(words).to include('inventory', 'tools', 'regression', 'list')
    end

    expect(Legion::JSON.dump(Legion::Settings::Extensions.find_tool(tool_name))).to eq(original)
    expect(Legion::JSON.dump(Legion::LLM::Tools::Special.inventory)).to eq(inventory)
  end

  it 'matches immutable trigger metadata without modifying it' do
    entry = Legion::Settings::Extensions.find_tool(tool_name)
    entry[:trigger_words].freeze

    expect(matcher.send(:trigger_words_for_entry, entry)).to include('inventory', 'tools', 'list')
  end
end
