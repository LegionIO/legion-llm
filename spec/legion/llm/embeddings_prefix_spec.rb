# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/embeddings'

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

  describe 'PREFIX_REGISTRY' do
    it 'maps nomic-embed-text to document and query prefixes' do
      expect(described_class::PREFIX_REGISTRY['nomic-embed-text']).to include(
        document: 'search_document: ',
        query:    'search_query: '
      )
    end

    it 'maps mxbai-embed-large to a query prefix only' do
      expect(described_class::PREFIX_REGISTRY['mxbai-embed-large']).to include(
        query: 'Represent this sentence for searching relevant passages: '
      )
      expect(described_class::PREFIX_REGISTRY['mxbai-embed-large'].key?(:document)).to be false
    end
  end

  describe '.generate with prefix injection' do
    context 'with nomic-embed-text model' do
      before do
        Legion::LLM.instance_variable_set(:@embedding_provider, :openai)
        Legion::LLM.instance_variable_set(:@embedding_model, 'nomic-embed-text')
      end

      it 'prepends document prefix by default' do
        expect(RubyLLM).to receive(:embed).with('search_document: hello', anything).and_return(mock_response)
        described_class.generate(text: 'hello', model: 'nomic-embed-text', provider: :openai)
      end

      it 'prepends document prefix when task: :document' do
        expect(RubyLLM).to receive(:embed).with('search_document: hello', anything).and_return(mock_response)
        described_class.generate(text: 'hello', model: 'nomic-embed-text', provider: :openai, task: :document)
      end

      it 'prepends query prefix when task: :query' do
        expect(RubyLLM).to receive(:embed).with('search_query: hello', anything).and_return(mock_response)
        described_class.generate(text: 'hello', model: 'nomic-embed-text', provider: :openai, task: :query)
      end
    end

    context 'with mxbai-embed-large model' do
      it 'prepends query prefix when task: :query' do
        expect(RubyLLM).to receive(:embed)
          .with('Represent this sentence for searching relevant passages: hello', anything)
          .and_return(mock_response)
        described_class.generate(text: 'hello', model: 'mxbai-embed-large', provider: :openai, task: :query)
      end

      it 'returns text unchanged for document task (no document prefix defined)' do
        expect(RubyLLM).to receive(:embed).with('hello', anything).and_return(mock_response)
        described_class.generate(text: 'hello', model: 'mxbai-embed-large', provider: :openai, task: :document)
      end
    end

    context 'with model variants using tag suffix' do
      it 'strips :latest tag and still applies prefix' do
        expect(RubyLLM).to receive(:embed).with('search_document: hello', anything).and_return(mock_response)
        described_class.generate(text: 'hello', model: 'nomic-embed-text:latest', provider: :openai, task: :document)
      end
    end

    context 'with unknown model' do
      it 'returns text unchanged' do
        expect(RubyLLM).to receive(:embed).with('hello world', anything).and_return(mock_response)
        described_class.generate(text: 'hello world', model: 'unknown-model', provider: :openai)
      end
    end

    context 'when default task is :document' do
      it 'uses :document when task is not specified' do
        expect(RubyLLM).to receive(:embed).with('search_document: test', anything).and_return(mock_response)
        described_class.generate(text: 'test', model: 'nomic-embed-text', provider: :openai)
      end
    end
  end

  describe '.generate with prefix_injection: false' do
    before do
      Legion::Settings[:llm][:embedding] = { prefix_injection: false }
    end

    it 'bypasses prefix for nomic-embed-text document task' do
      expect(RubyLLM).to receive(:embed).with('hello', anything).and_return(mock_response)
      described_class.generate(text: 'hello', model: 'nomic-embed-text', provider: :openai, task: :document)
    end

    it 'bypasses prefix for mxbai-embed-large query task' do
      expect(RubyLLM).to receive(:embed).with('hello', anything).and_return(mock_response)
      described_class.generate(text: 'hello', model: 'mxbai-embed-large', provider: :openai, task: :query)
    end
  end

  describe '.generate_batch with prefix injection' do
    let(:batch_response) do
      double('EmbedResponse', vectors: [Array.new(1024, 0.1), Array.new(1024, 0.2)])
    end

    it 'applies prefix to all texts in the batch' do
      expect(RubyLLM).to receive(:embed)
        .with(['search_document: foo', 'search_document: bar'], anything)
        .and_return(batch_response)
      described_class.generate_batch(texts: %w[foo bar], model: 'nomic-embed-text', provider: :openai, task: :document)
    end

    it 'applies query prefix to all texts in the batch' do
      expect(RubyLLM).to receive(:embed)
        .with(['search_query: foo', 'search_query: bar'], anything)
        .and_return(batch_response)
      described_class.generate_batch(texts: %w[foo bar], model: 'nomic-embed-text', provider: :openai, task: :query)
    end

    it 'passes texts unchanged for unknown model' do
      expect(RubyLLM).to receive(:embed)
        .with(%w[foo bar], anything)
        .and_return(batch_response)
      described_class.generate_batch(texts: %w[foo bar], model: 'unknown-model', provider: :openai)
    end

    context 'when prefix_injection: false' do
      before { Legion::Settings[:llm][:embedding] = { prefix_injection: false } }

      it 'does not modify any texts' do
        expect(RubyLLM).to receive(:embed)
          .with(%w[foo bar], anything)
          .and_return(batch_response)
        described_class.generate_batch(texts: %w[foo bar], model: 'nomic-embed-text', provider: :openai, task: :query)
      end
    end
  end
end
