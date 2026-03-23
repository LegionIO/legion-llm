# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Hooks::Reflection do
  before { described_class.reset! }

  describe '.should_extract?' do
    it 'returns true for substantive responses' do
      response = double('response', content: 'x' * 250)
      expect(described_class.should_extract?(response)).to be true
    end

    it 'returns false for short responses' do
      response = double('response', content: 'ok')
      expect(described_class.should_extract?(response)).to be false
    end

    it 'handles hash responses' do
      response = { content: 'x' * 250 }
      expect(described_class.should_extract?(response)).to be true
    end
  end

  describe '.extract_decisions' do
    it 'extracts decision patterns' do
      content = 'We decided to use PostgreSQL for the persistence layer because it supports JSON columns.'
      entries = described_class.extract_decisions(content)
      expect(entries).not_to be_empty
      expect(entries.first[:type]).to eq(:decision)
      expect(entries.first[:content]).to include('PostgreSQL')
    end

    it 'returns empty for no decisions' do
      entries = described_class.extract_decisions('Hello world')
      expect(entries).to be_empty
    end

    it 'limits to 2 entries' do
      content = 'We decided to use A for X. We chose B for Y. Going with C for Z.'
      entries = described_class.extract_decisions(content)
      expect(entries.size).to be <= 2
    end
  end

  describe '.extract_patterns' do
    it 'extracts pattern references' do
      content = 'The convention is to use snake_case for all method names in the framework.'
      entries = described_class.extract_patterns(content)
      expect(entries).not_to be_empty
      expect(entries.first[:type]).to eq(:pattern)
    end

    it 'extracts always/never rules' do
      content = 'Always use frozen string literals at the top of Ruby files for performance.'
      entries = described_class.extract_patterns(content)
      expect(entries).not_to be_empty
    end
  end

  describe '.extract_facts' do
    it 'extracts default values' do
      content = 'The default is port 4567 for the API server.'
      entries = described_class.extract_facts(content)
      expect(entries).not_to be_empty
      expect(entries.first[:type]).to eq(:fact)
    end

    it 'extracts version numbers' do
      content = 'This requires version 3.4.0 of Ruby to run properly.'
      entries = described_class.extract_facts(content)
      expect(entries).not_to be_empty
    end

    it 'extracts dependency information' do
      content = 'The LLM module requires legion-settings and legion-json to function.'
      entries = described_class.extract_facts(content)
      expect(entries).not_to be_empty
    end
  end

  describe '.analyze_for_knowledge' do
    it 'combines all extraction types' do
      content = 'We decided to use Redis for caching. The default port is 6379. ' \
                'The convention is to prefix all cache keys with the namespace.'
      messages = [{ role: 'user', content: 'How should we set up caching?' }]

      entries = described_class.analyze_for_knowledge(content, messages)
      types = entries.map { |e| e[:type] }.uniq
      expect(types.size).to be >= 2
      expect(entries.first[:context]).to include('caching')
    end
  end

  describe '.conversation_context' do
    it 'returns first user message as context' do
      messages = [
        { role: 'user', content: 'How does the routing system work?' },
        { role: 'assistant', content: 'The router uses...' }
      ]
      expect(described_class.conversation_context(messages)).to include('routing system')
    end

    it 'returns nil for empty messages' do
      expect(described_class.conversation_context([])).to be_nil
      expect(described_class.conversation_context(nil)).to be_nil
    end
  end

  describe '.summary' do
    it 'returns extraction statistics' do
      result = described_class.summary
      expect(result[:total_extractions]).to eq(0)
      expect(result[:by_type]).to eq({})
      expect(result[:recent]).to eq([])
    end
  end

  describe '.extract' do
    it 'extracts knowledge from a substantive response' do
      response = double('response',
                        content: 'We decided to use PostgreSQL because the default setting is compatible ' \
                                 'with our infrastructure. The convention is to always run migrations before deploy. ' \
                                 'This requires version 14.0 of PostgreSQL at minimum. ' + ('Additional context. ' * 20))
      messages = [{ role: 'user', content: 'What database should we use?' }]

      described_class.extract(response, messages, 'claude-sonnet-4-6')
      summary = described_class.summary
      expect(summary[:total_extractions]).to be > 0
    end

    it 'respects cooldown period' do
      response = double('response',
                        content: "We decided to use Redis for caching. #{'Details here. ' * 30}")
      messages = [{ role: 'user', content: 'Cache setup' }]

      described_class.extract(response, messages, 'claude-sonnet-4-6')
      first_count = described_class.summary[:total_extractions]

      described_class.extract(response, messages, 'claude-sonnet-4-6')
      expect(described_class.summary[:total_extractions]).to eq(first_count)
    end
  end
end
