# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/call/embeddings'

def native_embed_response(response = nil, vectors: nil, input_tokens: nil)
  vectors ||= response.vectors if response.respond_to?(:vectors)
  input_tokens ||= response.input_tokens if response.respond_to?(:input_tokens)
  {
    result: vectors || [Array.new(1024, 0.1)],
    usage:  Legion::LLM::Usage.new(input_tokens: input_tokens || 5)
  }
end

RSpec.describe Legion::LLM::Embeddings do
  before do
    Legion::LLM.instance_variable_set(:@started, true)
    Legion::LLM.instance_variable_set(:@embedding_provider, :openai)
    Legion::LLM.instance_variable_set(:@embedding_model, 'text-embedding-3-small')
    Legion::Settings[:llm][:providers][:openai][:enabled] = true
    Legion::Settings[:llm][:embedding] ||= {}
    Legion::Settings[:llm][:embedding].delete(:prefix_injection)
  end

  after do
    Legion::LLM.instance_variable_set(:@started, nil)
    Legion::LLM.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM.instance_variable_set(:@embedding_model, nil)
  end

  let(:mock_response) do
    double('EmbedResponse', vectors: [Array.new(1024, 0.1)], input_tokens: 5)
  end

  describe 'prefix_registry setting' do
    let(:registry) { Legion::LLM::Settings.embedding_defaults[:prefix_registry] }

    it 'maps nomic-embed-text to document and query prefixes' do
      expect(registry['nomic-embed-text']).to include(
        document: 'search_document: ',
        query:    'search_query: '
      )
    end

    it 'maps mxbai-embed-large to a query prefix only' do
      expect(registry['mxbai-embed-large']).to include(
        query: 'Represent this sentence for searching relevant passages: '
      )
      expect(registry['mxbai-embed-large'].key?(:document)).to be false
    end
  end

  describe '.generate with prefix injection' do
    context 'with nomic-embed-text model' do
      before do
        Legion::LLM.instance_variable_set(:@embedding_provider, :openai)
        Legion::LLM.instance_variable_set(:@embedding_model, 'nomic-embed-text')
      end

      it 'prepends document prefix by default' do
        expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
          .with(hash_including(text: 'search_document: hello')).and_return(native_embed_response(mock_response))
        described_class.generate(text: 'hello', model: 'nomic-embed-text', provider: :openai)
      end

      it 'prepends document prefix when task: :document' do
        expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
          .with(hash_including(text: 'search_document: hello')).and_return(native_embed_response(mock_response))
        described_class.generate(text: 'hello', model: 'nomic-embed-text', provider: :openai, task: :document)
      end

      it 'prepends query prefix when task: :query' do
        expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
          .with(hash_including(text: 'search_query: hello')).and_return(native_embed_response(mock_response))
        described_class.generate(text: 'hello', model: 'nomic-embed-text', provider: :openai, task: :query)
      end
    end

    context 'with mxbai-embed-large model' do
      it 'prepends query prefix when task: :query' do
        expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
          .with(hash_including(text: 'Represent this sentence for searching relevant passages: hello'))
          .and_return(native_embed_response(mock_response))
        described_class.generate(text: 'hello', model: 'mxbai-embed-large', provider: :openai, task: :query)
      end

      it 'returns text unchanged for document task (no document prefix defined)' do
        expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
          .with(hash_including(text: 'hello')).and_return(native_embed_response(mock_response))
        described_class.generate(text: 'hello', model: 'mxbai-embed-large', provider: :openai, task: :document)
      end
    end

    context 'with model variants using tag suffix' do
      it 'strips :latest tag and still applies prefix' do
        expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
          .with(hash_including(text: 'search_document: hello')).and_return(native_embed_response(mock_response))
        described_class.generate(text: 'hello', model: 'nomic-embed-text:latest', provider: :openai, task: :document)
      end
    end

    context 'with unknown model' do
      it 'returns text unchanged' do
        expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
          .with(hash_including(text: 'hello world')).and_return(native_embed_response(mock_response))
        described_class.generate(text: 'hello world', model: 'unknown-model', provider: :openai)
      end
    end

    context 'when default task is :document' do
      it 'uses :document when task is not specified' do
        expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
          .with(hash_including(text: 'search_document: test')).and_return(native_embed_response(mock_response))
        described_class.generate(text: 'test', model: 'nomic-embed-text', provider: :openai)
      end
    end
  end

  describe '.generate with prefix_injection: false' do
    before do
      Legion::Settings[:llm][:embedding] = { prefix_injection: false }
    end

    it 'bypasses prefix for nomic-embed-text document task' do
      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
        .with(hash_including(text: 'hello')).and_return(native_embed_response(mock_response))
      described_class.generate(text: 'hello', model: 'nomic-embed-text', provider: :openai, task: :document)
    end

    it 'bypasses prefix for mxbai-embed-large query task' do
      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
        .with(hash_including(text: 'hello')).and_return(native_embed_response(mock_response))
      described_class.generate(text: 'hello', model: 'mxbai-embed-large', provider: :openai, task: :query)
    end
  end

  describe '.generate with JSON-loaded prefix settings' do
    before do
      Legion::Settings[:llm]['embedding'] = {
        'prefix_registry' => {
          'custom-embed' => {
            'query' => 'query: '
          }
        }
      }
    end

    it 'uses string-keyed prefix registry entries' do
      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
        .with(hash_including(text: 'query: hello')).and_return(native_embed_response(mock_response))
      described_class.generate(text: 'hello', model: 'custom-embed', provider: :openai, task: :query)
    end
  end

  describe '.generate_batch with prefix injection' do
    let(:batch_response) do
      double('EmbedResponse', vectors: [Array.new(1024, 0.1), Array.new(1024, 0.2)])
    end

    it 'applies prefix to all texts in the batch' do
      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
        .with(hash_including(text: ['search_document: foo', 'search_document: bar']))
        .and_return(native_embed_response(batch_response))
      described_class.generate_batch(texts: %w[foo bar], model: 'nomic-embed-text', provider: :openai, task: :document)
    end

    it 'applies query prefix to all texts in the batch' do
      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
        .with(hash_including(text: ['search_query: foo', 'search_query: bar']))
        .and_return(native_embed_response(batch_response))
      described_class.generate_batch(texts: %w[foo bar], model: 'nomic-embed-text', provider: :openai, task: :query)
    end

    it 'passes texts unchanged for unknown model' do
      expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
        .with(hash_including(text: %w[foo bar]))
        .and_return(native_embed_response(batch_response))
      described_class.generate_batch(texts: %w[foo bar], model: 'unknown-model', provider: :openai)
    end

    context 'when prefix_injection: false' do
      before { Legion::Settings[:llm][:embedding] = { prefix_injection: false } }

      it 'does not modify any texts' do
        expect(Legion::LLM::Call::Dispatch).to receive(:dispatch_embed)
          .with(hash_including(text: %w[foo bar]))
          .and_return(native_embed_response(batch_response))
        described_class.generate_batch(texts: %w[foo bar], model: 'nomic-embed-text', provider: :openai, task: :query)
      end
    end
  end
end
