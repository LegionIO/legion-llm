# frozen_string_literal: true

require 'spec_helper'
require 'json'

# Stub Legion::JSON if not already defined (legion-json gem not loaded in test)
unless defined?(Legion::JSON)
  module Legion
    module JSON
      class << self
        def load(str)
          ::JSON.parse(str, symbolize_names: true)
        end

        def dump(obj)
          ::JSON.generate(obj)
        end
      end
    end
  end
end

require 'legion/llm/structured_output'

RSpec.describe Legion::LLM::StructuredOutput do
  let(:schema) { { type: 'object', properties: { name: { type: 'string' } } } }
  let(:messages) { [{ role: 'user', content: 'Give me a name' }] }

  describe '.generate' do
    it 'returns parsed JSON when valid' do
      json_string = '{"name":"Alice"}'
      allow(Legion::LLM).to receive(:send).with(:chat_single, anything).and_return({ content: json_string, model: 'gpt-4o' })
      allow(Legion::JSON).to receive(:load).with(json_string).and_return({ name: 'Alice' })
      allow(Legion::JSON).to receive(:dump).and_return('{}')

      result = described_class.generate(messages: messages, schema: schema, model: 'gpt-4o')
      expect(result[:valid]).to be true
      expect(result[:data]).to eq({ name: 'Alice' })
    end

    it 'retries on parse failure' do
      bad_result = { content: 'not json', model: 'gpt-4o' }
      good_result = { content: '{"name":"Bob"}', model: 'gpt-4o' }

      call_count = 0
      allow(Legion::LLM).to receive(:send).with(:chat_single, anything) do
        call_count += 1
        call_count == 1 ? bad_result : good_result
      end

      allow(Legion::JSON).to receive(:dump).and_return('{}')
      allow(Legion::JSON).to receive(:load).with('not json').and_raise(JSON::ParserError, 'unexpected token')
      allow(Legion::JSON).to receive(:load).with('{"name":"Bob"}').and_return({ name: 'Bob' })
      allow(Legion::Settings).to receive(:dig).with(:llm, :structured_output, :retry_on_parse_failure).and_return(true)
      allow(Legion::Settings).to receive(:dig).with(:llm, :structured_output, :max_retries).and_return(2)

      result = described_class.generate(messages: messages, schema: schema, model: 'gpt-4o')
      expect(result[:valid]).to be true
      expect(result[:retried]).to be true
    end

    it 'returns error when retries exhausted' do
      bad_result = { content: 'bad', model: 'gpt-4o' }
      allow(Legion::LLM).to receive(:send).with(:chat_single, anything).and_return(bad_result)
      allow(Legion::JSON).to receive(:dump).and_return('{}')
      allow(Legion::JSON).to receive(:load).and_raise(JSON::ParserError, 'unexpected token')
      allow(Legion::Settings).to receive(:dig).with(:llm, :structured_output, :retry_on_parse_failure).and_return(false)

      result = described_class.generate(messages: messages, schema: schema, model: 'gpt-4o')
      expect(result[:valid]).to be false
      expect(result[:error]).to include('JSON parse failed')
    end
  end

  describe '.supports_response_format?' do
    it 'recognizes schema-capable models' do
      expect(described_class.send(:supports_response_format?, 'gpt-4o')).to be true
      expect(described_class.send(:supports_response_format?, 'gpt-4o-mini')).to be true
      expect(described_class.send(:supports_response_format?, 'claude-4-sonnet')).to be true
    end

    it 'rejects unsupported models' do
      expect(described_class.send(:supports_response_format?, 'llama3')).to be false
    end
  end
end
