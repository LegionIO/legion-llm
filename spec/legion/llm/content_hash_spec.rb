# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/content_hash'

RSpec.describe Legion::LLM::ContentHash do
  describe '.call' do
    it 'returns nil for nil' do
      expect(described_class.call(nil)).to be_nil
    end

    it 'returns nil for empty string' do
      expect(described_class.call('')).to be_nil
    end

    it 'returns the SHA-256 of a string' do
      expected = Digest::SHA256.hexdigest('hello world')
      expect(described_class.call('hello world')).to eq(expected)
    end

    it 'is deterministic' do
      digest_a = described_class.call('repeat me')
      digest_b = described_class.call('repeat me')
      expect(digest_a).to eq(digest_b)
    end

    it 'differs across distinct inputs' do
      expect(described_class.call('a')).not_to eq(described_class.call('b'))
    end

    it 'concatenates message arrays with newlines and hashes the result' do
      messages = [{ role: 'user', content: 'hi' }, { role: 'assistant', content: 'there' }]
      expected = Digest::SHA256.hexdigest("hi\nthere")
      expect(described_class.call(messages)).to eq(expected)
    end

    it 'prefers string-key content over symbol-key content (matches AuditPublisher precedence)' do
      messages = [{ 'content' => 'string-key wins', :content => 'sym-key loses' }]
      expected = Digest::SHA256.hexdigest('string-key wins')
      expect(described_class.call(messages)).to eq(expected)
    end

    it 'falls back to message.to_s when no content key present' do
      messages = [{ role: 'user' }]
      digest = described_class.call(messages)
      expect(digest).to be_a(String)
      expect(digest.length).to eq(64)
    end

    it 'handles non-string content via to_s' do
      digest = described_class.call(12_345)
      expect(digest).to eq(Digest::SHA256.hexdigest('12345'))
    end
  end

  describe 'compatibility with the prior AuditPublisher implementation' do
    # The old private content_hash inside AuditPublisher used hash_value (string-key
    # first, symbol-key second). Records already in the ledger were generated with
    # that precedence, so the digest must remain byte-identical.
    it 'produces the same digest as the original AuditPublisher#content_hash' do
      content = [
        { 'content' => 'first', role: 'user' },
        { content: 'second', role: 'assistant' }
      ]
      expected = Digest::SHA256.hexdigest("first\nsecond")
      expect(described_class.call(content)).to eq(expected)
    end
  end
end
