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

# Pipeline-Response shape (message hash + routing hash) returned by Prompt.dispatch.
PipelineResponseStub = Struct.new(:message, :routing, keyword_init: true)

RSpec.describe Legion::LLM::Call::StructuredOutput do
  let(:schema) { { type: 'object', properties: { name: { type: 'string' } } } }
  let(:messages) { [{ role: 'user', content: 'Give me a name' }] }

  def pipeline_response(content:, model:)
    PipelineResponseStub.new(message: { role: 'assistant', content: content }, routing: { model: model })
  end

  describe '.generate' do
    it 'routes through Prompt.dispatch (canonical Request/Executor path), never chat_single' do
      json_string = '{"name":"Alice"}'
      expect(Legion::LLM::Inference::Prompt).to receive(:dispatch)
        .with(messages, hash_including(model: 'gpt-4o', schema: schema))
        .and_return(pipeline_response(content: json_string, model: 'gpt-4o'))
      allow(Legion::JSON).to receive(:load).with(json_string).and_return({ name: 'Alice' })

      result = described_class.generate(messages: messages, schema: schema, model: 'gpt-4o')
      expect(result[:valid]).to be true
      expect(result[:data]).to eq({ name: 'Alice' })
    end

    it 'forwards an explicit provider and model to Prompt.dispatch' do
      json_string = '{"name":"Alice"}'
      expect(Legion::LLM::Inference::Prompt).to receive(:dispatch)
        .with(messages, hash_including(model: 'claude-sonnet-4-6', provider: :anthropic, schema: schema))
        .and_return(pipeline_response(content: json_string, model: 'claude-sonnet-4-6'))
      allow(Legion::JSON).to receive(:load).with(json_string).and_return({ name: 'Alice' })

      result = described_class.generate(messages: messages, schema: schema,
                                        model: 'claude-sonnet-4-6', provider: :anthropic)
      expect(result[:valid]).to be true
    end

    it 'does NOT inject a default model/provider when none is supplied (SSOT selects)' do
      json_string = '{"name":"Alice"}'
      expect(Legion::LLM::Inference::Prompt).to receive(:dispatch)
        .with(messages, hash_including(model: nil, provider: nil, schema: schema))
        .and_return(pipeline_response(content: json_string, model: 'router-selected-model'))
      allow(Legion::JSON).to receive(:load).with(json_string).and_return({ name: 'Alice' })

      result = described_class.generate(messages: messages, schema: schema)
      expect(result[:valid]).to be true
      expect(result[:model]).to eq('router-selected-model')
    end

    it 'handles hash-shaped results returned by dispatch' do
      json_string = '{"name":"Alice"}'
      allow(Legion::LLM::Inference::Prompt).to receive(:dispatch)
        .and_return({ content: json_string, model: 'qwen3.6:27b-q4_K_M' })
      allow(Legion::JSON).to receive(:load).with(json_string).and_return({ name: 'Alice' })

      result = described_class.generate(messages: messages, schema: schema, model: 'qwen3.6:27b-q4_K_M')
      expect(result[:valid]).to be true
      expect(result[:data]).to eq({ name: 'Alice' })
      expect(result[:model]).to eq('qwen3.6:27b-q4_K_M')
    end

    it 'strips markdown code fences before parsing JSON' do
      fenced = "```json\n{\"name\":\"Alice\"}\n```"
      allow(Legion::LLM::Inference::Prompt).to receive(:dispatch)
        .and_return(pipeline_response(content: fenced, model: 'qwen3.6'))
      allow(Legion::JSON).to receive(:load).with('{"name":"Alice"}').and_return({ name: 'Alice' })

      result = described_class.generate(messages: messages, schema: schema, model: 'qwen3.6')
      expect(result[:valid]).to be true
      expect(result[:raw]).to eq('{"name":"Alice"}')
      expect(result[:data]).to eq({ name: 'Alice' })
    end

    it 'retries on parse failure by re-requesting through the same path' do
      call_count = 0
      allow(Legion::LLM::Inference::Prompt).to receive(:dispatch) do
        call_count += 1
        if call_count == 1
          pipeline_response(content: 'not json', model: 'gpt-4o')
        else
          pipeline_response(content: '{"name":"Bob"}', model: 'gpt-4o')
        end
      end
      allow(Legion::JSON).to receive(:load).with('not json').and_raise(Legion::JSON::ParseError, 'unexpected token')
      allow(Legion::JSON).to receive(:load).with('{"name":"Bob"}').and_return({ name: 'Bob' })
      Legion::Settings[:llm][:structured_output][:retry_on_parse_failure] = true
      Legion::Settings[:llm][:structured_output][:max_retries] = 2

      result = described_class.generate(messages: messages, schema: schema, model: 'gpt-4o')
      expect(result[:valid]).to be true
      expect(result[:retried]).to be true
    end

    it 'strips markdown code fences from retry responses before parsing JSON' do
      call_count = 0
      allow(Legion::LLM::Inference::Prompt).to receive(:dispatch) do
        call_count += 1
        if call_count == 1
          pipeline_response(content: 'not json', model: 'gpt-4o')
        else
          pipeline_response(content: "```\n{\"name\":\"Bob\"}\n```", model: 'gpt-4o')
        end
      end
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
      allow(Legion::LLM::Inference::Prompt).to receive(:dispatch)
        .and_return(pipeline_response(content: 'bad', model: 'gpt-4o'))
      allow(Legion::JSON).to receive(:load).and_raise(Legion::JSON::ParseError, 'unexpected token')
      Legion::Settings[:llm][:structured_output] = { retry_on_parse_failure: false }

      result = described_class.generate(messages: messages, schema: schema, model: 'gpt-4o')
      expect(result[:valid]).to be false
      expect(result[:error]).to include('JSON parse failed')
    end
  end
end
