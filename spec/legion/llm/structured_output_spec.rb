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

require 'legion/llm/call/structured_output'

ProviderMessage = Struct.new(:content, :model_id, keyword_init: true)

RSpec.describe Legion::LLM::Call::StructuredOutput do
  let(:schema) { { type: 'object', properties: { name: { type: 'string' } } } }
  let(:messages) { [{ role: 'user', content: 'Give me a name' }] }

  describe '.generate' do
    it 'returns parsed JSON when valid' do
      json_string = '{"name":"Alice"}'
      allow(Legion::LLM::Inference).to receive(:send).with(:chat_single, anything).and_return({ content: json_string, model: 'gpt-4o' })
      allow(Legion::JSON).to receive(:load).with(json_string).and_return({ name: 'Alice' })
      allow(Legion::JSON).to receive(:dump).and_return('{}')

      result = described_class.generate(messages: messages, schema: schema, model: 'gpt-4o')
      expect(result[:valid]).to be true
      expect(result[:data]).to eq({ name: 'Alice' })
    end

    it 'handles ProviderMessage objects returned by chat_single' do
      json_string = '{"name":"Alice"}'
      msg = ProviderMessage.new(content: json_string, model_id: 'qwen3.6:27b-q4_K_M')
      allow(Legion::LLM::Inference).to receive(:send).with(:chat_single, anything).and_return(msg)
      allow(Legion::JSON).to receive(:load).with(json_string).and_return({ name: 'Alice' })
      allow(Legion::JSON).to receive(:dump).and_return('{}')

      result = described_class.generate(messages: messages, schema: schema, model: 'qwen3.6:27b-q4_K_M')
      expect(result[:valid]).to be true
      expect(result[:data]).to eq({ name: 'Alice' })
      expect(result[:model]).to eq('qwen3.6:27b-q4_K_M')
    end

    it 'strips markdown code fences before parsing JSON' do
      fenced = "```json\n{\"name\":\"Alice\"}\n```"
      allow(Legion::LLM::Inference).to receive(:send).with(:chat_single, anything).and_return({ content: fenced, model: 'qwen3.6' })
      allow(Legion::JSON).to receive(:load).with('{"name":"Alice"}').and_return({ name: 'Alice' })
      allow(Legion::JSON).to receive(:dump).and_return('{}')

      result = described_class.generate(messages: messages, schema: schema, model: 'qwen3.6')

      expect(result[:valid]).to be true
      expect(result[:raw]).to eq('{"name":"Alice"}')
      expect(result[:data]).to eq({ name: 'Alice' })
    end

    it 'passes provider through to chat_single' do
      json_string = '{"name":"Alice"}'
      allow(Legion::LLM::Inference).to receive(:send).with(
        :chat_single,
        hash_including(model: 'claude-sonnet-4-6', provider: :anthropic)
      ).and_return({ content: json_string, model: 'claude-sonnet-4-6' })
      allow(Legion::JSON).to receive(:load).with(json_string).and_return({ name: 'Alice' })
      allow(Legion::JSON).to receive(:dump).and_return('{}')

      result = described_class.generate(
        messages: messages,
        schema:   schema,
        model:    'claude-sonnet-4-6',
        provider: :anthropic
      )

      expect(result[:valid]).to be true
    end

    it 'retries on parse failure' do
      bad_result = { content: 'not json', model: 'gpt-4o' }
      good_result = { content: '{"name":"Bob"}', model: 'gpt-4o' }

      call_count = 0
      allow(Legion::LLM::Inference).to receive(:send).with(:chat_single, anything) do
        call_count += 1
        call_count == 1 ? bad_result : good_result
      end

      allow(Legion::JSON).to receive(:dump).and_return('{}')
      allow(Legion::JSON).to receive(:load).with('not json').and_raise(Legion::JSON::ParseError, 'unexpected token')
      allow(Legion::JSON).to receive(:load).with('{"name":"Bob"}').and_return({ name: 'Bob' })
      Legion::Settings[:llm][:structured_output][:retry_on_parse_failure] = true
      Legion::Settings[:llm][:structured_output][:max_retries] = 2

      result = described_class.generate(messages: messages, schema: schema, model: 'gpt-4o')
      expect(result[:valid]).to be true
      expect(result[:retried]).to be true
    end

    it 'escalates parse retry to an alternate route when available' do
      bad_result = { content: 'not json', model: 'primary-model' }
      good_result = { content: '{"name":"Bob"}', model: 'backup-model' }
      route = Legion::LLM::Router::Resolution.new(provider: :bedrock, model: 'backup-model', tier: :cloud)

      allow(Legion::LLM::Router).to receive(:resolve_chain).and_return([route])
      allow(Legion::JSON).to receive(:dump).and_return('{}')
      allow(Legion::JSON).to receive(:load).with('not json').and_raise(Legion::JSON::ParseError, 'unexpected token')
      allow(Legion::JSON).to receive(:load).with('{"name":"Bob"}').and_return({ name: 'Bob' })
      allow(Legion::Settings).to receive(:dig).with(:llm, :structured_output, :retry_on_parse_failure).and_return(true)
      allow(Legion::Settings).to receive(:dig).with(:llm, :structured_output, :max_retries).and_return(2)

      expect(Legion::LLM::Inference).to receive(:send).with(
        :chat_single,
        hash_including(model: 'primary-model', provider: :ollama)
      ).and_return(bad_result)
      expect(Legion::LLM::Inference).to receive(:send).with(
        :chat_single,
        hash_including(model: 'backup-model', provider: :bedrock)
      ).and_return(good_result)

      result = described_class.generate(messages: messages, schema: schema, model: 'primary-model', provider: :ollama)

      expect(result[:valid]).to be true
      expect(result[:retried]).to be true
      expect(result[:retry_route]).to include(model: 'backup-model', provider: :bedrock)
    end

    it 'strips markdown code fences from retry responses before parsing JSON' do
      bad_result = { content: 'not json', model: 'gpt-4o' }
      good_result = { content: "```\n{\"name\":\"Bob\"}\n```", model: 'gpt-4o' }

      call_count = 0
      allow(Legion::LLM::Inference).to receive(:send).with(:chat_single, anything) do
        call_count += 1
        call_count == 1 ? bad_result : good_result
      end

      allow(Legion::JSON).to receive(:dump).and_return('{}')
      allow(Legion::JSON).to receive(:load).with('not json').and_raise(Legion::JSON::ParseError, 'unexpected token')
      allow(Legion::JSON).to receive(:load).with('{"name":"Bob"}').and_return({ name: 'Bob' })
      Legion::Settings[:llm][:structured_output][:retry_on_parse_failure] = true
      Legion::Settings[:llm][:structured_output][:max_retries] = 2

      result = described_class.generate(messages: messages, schema: schema, model: 'gpt-4o')

      expect(result[:valid]).to be true
      expect(result[:raw]).to eq('{"name":"Bob"}')
      expect(result[:retried]).to be true
    end

    it 'returns error when retries exhausted' do
      bad_result = { content: 'bad', model: 'gpt-4o' }
      allow(Legion::LLM::Inference).to receive(:send).with(:chat_single, anything).and_return(bad_result)
      allow(Legion::JSON).to receive(:dump).and_return('{}')
      allow(Legion::JSON).to receive(:load).and_raise(Legion::JSON::ParseError, 'unexpected token')
      Legion::Settings[:llm][:structured_output] = { retry_on_parse_failure: false }

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
