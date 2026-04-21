# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Context::Compressor do
  describe '.compress' do
    context 'with level 0 (none)' do
      it 'returns text unchanged' do
        text = 'The quick brown fox jumps over the lazy dog'
        expect(described_class.compress(text, level: 0)).to eq(text)
      end
    end

    context 'with nil or empty input' do
      it 'returns nil for nil input' do
        expect(described_class.compress(nil, level: 1)).to be_nil
      end

      it 'returns empty string for empty input' do
        expect(described_class.compress('', level: 1)).to eq('')
      end
    end

    context 'with level 1 (light)' do
      it 'removes articles' do
        expect(described_class.compress('The quick brown fox jumps over a lazy dog', level: 1))
          .to eq('quick brown fox jumps over lazy dog')
      end

      it 'removes filler adverbs' do
        expect(described_class.compress('This is just very really important', level: 1))
          .to eq('This is important')
      end

      it 'handles case-insensitive removal' do
        expect(described_class.compress('The server and the client', level: 1))
          .to eq('server and client')
      end

      it 'does not remove words that contain stopwords' do
        expect(described_class.compress('theme another theatrical', level: 1))
          .to eq('theme another theatrical')
      end

      it 'preserves negation words' do
        text = 'Do not remove the negation'
        expect(described_class.compress(text, level: 1)).to include('not')
        expect(described_class.compress(text, level: 1)).to include('Do')
      end
    end

    context 'with level 2 (moderate)' do
      it 'removes connectives' do
        text = 'First step. However the next step is important. Furthermore it matters.'
        result = described_class.compress(text, level: 2)
        expect(result).not_to include('However')
        expect(result).not_to include('Furthermore')
      end

      it 'includes level 1 removals' do
        text = 'The server is just very important. However it works.'
        result = described_class.compress(text, level: 2)
        expect(result).not_to include('The ')
        expect(result).not_to include('just')
        expect(result).not_to include('However')
      end
    end

    context 'with level 3 (aggressive)' do
      it 'removes additional low-signal words' do
        text = 'Please note that also the system then works'
        result = described_class.compress(text, level: 3)
        expect(result).not_to include('Please')
        expect(result).not_to include('also')
        expect(result).not_to include('then')
      end

      it 'collapses multiple spaces' do
        text = 'The   very   important   thing'
        result = described_class.compress(text, level: 3)
        expect(result).not_to include('  ')
      end

      it 'collapses excessive blank lines' do
        text = "line one\n\n\n\nline two"
        result = described_class.compress(text, level: 3)
        expect(result).to eq("line one\n\nline two")
      end
    end

    context 'with code block protection' do
      it 'does not modify fenced code blocks' do
        text = "Remove the articles\n```\nthe quick brown fox\n```\nRemove the articles"
        result = described_class.compress(text, level: 1)
        expect(result).to include('the quick brown fox')
        expect(result).to start_with('Remove articles')
      end

      it 'does not modify inline code' do
        text = 'Remove the articles but keep `the value` intact'
        result = described_class.compress(text, level: 1)
        expect(result).to include('`the value`')
        expect(result).to start_with('Remove articles')
      end

      it 'handles mixed code and prose' do
        text = "The function `the_helper` is just very useful.\n```ruby\nthe = get_the_value\n```\nThe end."
        result = described_class.compress(text, level: 1)
        expect(result).to include('`the_helper`')
        expect(result).to include('the = get_the_value')
        expect(result).to include('end.')
      end
    end

    context 'determinism' do
      it 'produces identical output for identical input' do
        text = 'The quick brown fox jumps over the lazy dog'
        result1 = described_class.compress(text, level: 2)
        result2 = described_class.compress(text, level: 2)
        expect(result1).to eq(result2)
      end
    end

    context 'defaults' do
      it 'defaults to level 1' do
        text = 'The quick brown fox'
        expect(described_class.compress(text)).to eq(described_class.compress(text, level: 1))
      end
    end
  end

  describe '.summarize_messages' do
    it 'returns empty summary for nil messages' do
      result = described_class.summarize_messages(nil)
      expect(result[:summary]).to eq('')
      expect(result[:original_count]).to eq(0)
    end

    it 'returns empty summary for empty messages' do
      result = described_class.summarize_messages([])
      expect(result[:summary]).to eq('')
      expect(result[:original_count]).to eq(0)
    end

    it 'returns uncompressed for short conversations' do
      messages = [
        { role: 'user', content: 'hello' },
        { role: 'assistant', content: 'hi' }
      ]
      result = described_class.summarize_messages(messages)
      expect(result[:compressed]).to be false
      expect(result[:original_count]).to eq(2)
    end

    it 'falls back to stopword compression when LLM unavailable' do
      long_messages = 200.times.map do |i|
        { role: i.even? ? 'user' : 'assistant', content: "This is a very really just quite important message number #{i} with lots of content." }
      end
      result = described_class.summarize_messages(long_messages, max_tokens: 500)
      expect(result[:compressed]).to be true
      expect(result[:method]).to eq(:stopword)
    end

    it 'uses LLM when available' do
      fake_response = double('Response', content: 'Summary of conversation')
      fake_session = double('Session')
      allow(fake_session).to receive(:ask).and_return(fake_response)

      llm_mod = Module.new do
        def self.chat_direct(**)
          @session
        end
      end
      llm_mod.instance_variable_set(:@session, fake_session)
      stub_const('Legion::LLM', llm_mod)

      long_messages = 200.times.map do |i|
        { role: i.even? ? 'user' : 'assistant', content: "Important message #{i} with significant content here." }
      end
      result = described_class.summarize_messages(long_messages, max_tokens: 500)
      expect(result[:compressed]).to be true
      expect(result[:summary]).to eq('Summary of conversation')
    end
  end

  describe '.deduplicate_messages' do
    it 'returns empty for nil' do
      result = described_class.deduplicate_messages(nil)
      expect(result[:messages]).to eq([])
      expect(result[:removed]).to eq(0)
    end

    it 'keeps unique messages' do
      messages = [
        { role: 'user', content: 'How does caching work in Legion?' },
        { role: 'assistant', content: 'Legion uses Redis or Memcached via legion-cache.' },
        { role: 'user', content: 'What about persistence?' }
      ]
      result = described_class.deduplicate_messages(messages)
      expect(result[:messages].size).to eq(3)
      expect(result[:removed]).to eq(0)
    end

    it 'removes near-duplicate messages keeping the last occurrence' do
      messages = [
        { role: 'user', content: 'How does the caching system work in Legion framework?' },
        { role: 'assistant', content: 'It uses Redis.' },
        { role: 'user', content: 'How does the caching system work in the Legion framework?' }
      ]
      result = described_class.deduplicate_messages(messages)
      expect(result[:removed]).to eq(1)
      expect(result[:messages].size).to eq(2)
      expect(result[:messages].last[:content]).to include('Legion framework')
    end

    it 'skips very short messages' do
      messages = [
        { role: 'user', content: 'yes' },
        { role: 'assistant', content: 'ok' },
        { role: 'user', content: 'yes' }
      ]
      result = described_class.deduplicate_messages(messages)
      expect(result[:removed]).to eq(0)
    end

    it 'only deduplicates within the same role' do
      messages = [
        { role: 'user', content: 'The caching system uses Redis and Memcached for storage.' },
        { role: 'assistant', content: 'The caching system uses Redis and Memcached for storage.' }
      ]
      result = described_class.deduplicate_messages(messages)
      expect(result[:removed]).to eq(0)
    end

    it 'respects custom threshold' do
      messages = [
        { role: 'user', content: 'Tell me about the caching system in Legion please.' },
        { role: 'assistant', content: 'Sure, here is the info.' },
        { role: 'user', content: 'Tell me about caching in Legion.' }
      ]
      # With a very high threshold (0.99), these should not be considered duplicates
      result = described_class.deduplicate_messages(messages, threshold: 0.99)
      expect(result[:removed]).to eq(0)

      # With a lower threshold, they should be deduplicated
      result = described_class.deduplicate_messages(messages, threshold: 0.5)
      expect(result[:removed]).to eq(1)
    end
  end

  describe '.stopwords_for_level' do
    it 'returns empty array for level 0' do
      expect(described_class.stopwords_for_level(0)).to be_empty
    end

    it 'accumulates words across levels' do
      l1 = described_class.stopwords_for_level(1)
      l2 = described_class.stopwords_for_level(2)
      l3 = described_class.stopwords_for_level(3)

      expect(l1).not_to be_empty
      expect(l2.length).to be > l1.length
      expect(l3.length).to be > l2.length
      expect(l2).to include(*l1)
      expect(l3).to include(*l2)
    end
  end
end
