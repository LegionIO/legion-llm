# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/skills/external_discovery'

RSpec.describe Legion::LLM::Skills::ExternalDiscovery do
  describe '.claude_directories' do
    it 'includes ~/.claude/skills when it exists' do
      expect(::File).to receive(:directory?)
        .with(::File.expand_path('~/.claude/skills')).and_return(true)
      allow(::File).to receive(:directory?).and_call_original
      allow(::Dir).to receive(:glob).and_return([])
      dirs = described_class.claude_directories
      expect(dirs).to include(::File.expand_path('~/.claude/skills'))
    end

    it 'returns empty array when ~/.claude/skills does not exist' do
      allow(::File).to receive(:directory?).and_return(false)
      expect(described_class.claude_directories).to eq([])
    end
  end

  describe '.codex_directories' do
    it 'returns empty array when ~/.codex/skills does not exist' do
      allow(::File).to receive(:directory?).and_return(false)
      expect(described_class.codex_directories).to eq([])
    end
  end

  describe '.discover' do
    it 'returns empty array when all auto_discover settings are false' do
      allow(Legion::LLM).to receive(:settings)
        .and_return({ skills: { auto_discover: { claude: false, codex: false } } })
      expect(described_class.discover).to eq([])
    end
  end
end
