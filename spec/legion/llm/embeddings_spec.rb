# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/embeddings'

RSpec.describe 'Legion::LLM embedding capability' do
  before do
    Legion::LLM.instance_variable_set(:@can_embed, nil)
    Legion::LLM.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM.instance_variable_set(:@embedding_model, nil)
  end

  describe '.can_embed?' do
    it 'returns false before detection' do
      Legion::LLM.instance_variable_set(:@can_embed, nil)
      expect(Legion::LLM.can_embed?).to be false
    end

    it 'returns true after successful detection' do
      Legion::LLM.instance_variable_set(:@can_embed, true)
      expect(Legion::LLM.can_embed?).to be true
    end
  end

  describe '.embedding_provider' do
    it 'returns the detected provider symbol' do
      Legion::LLM.instance_variable_set(:@embedding_provider, :ollama)
      expect(Legion::LLM.embedding_provider).to eq(:ollama)
    end
  end

  describe '.embedding_model' do
    it 'returns the detected model string' do
      Legion::LLM.instance_variable_set(:@embedding_model, 'mxbai-embed-large')
      expect(Legion::LLM.embedding_model).to eq('mxbai-embed-large')
    end
  end
end

RSpec.describe '.detect_embedding_capability' do
  before do
    Legion::LLM.instance_variable_set(:@can_embed, nil)
    Legion::LLM.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM.instance_variable_set(:@embedding_model, nil)
  end

  context 'when Ollama has a preferred model' do
    before do
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?)
        .and_return(false)
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?)
        .with('mxbai-embed-large').and_return(true)
    end

    it 'selects Ollama with that model' do
      Legion::LLM.send(:detect_embedding_capability)
      expect(Legion::LLM.can_embed?).to be true
      expect(Legion::LLM.embedding_provider).to eq(:ollama)
      expect(Legion::LLM.embedding_model).to eq('mxbai-embed-large')
    end
  end

  context 'when Ollama has no models but bedrock is configured' do
    before do
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?)
        .and_return(false)
      Legion::Settings[:llm][:providers][:bedrock][:enabled] = true
    end

    it 'falls back to bedrock' do
      Legion::LLM.send(:detect_embedding_capability)
      expect(Legion::LLM.can_embed?).to be true
      expect(Legion::LLM.embedding_provider).to eq(:bedrock)
      expect(Legion::LLM.embedding_model).to eq('amazon.titan-embed-text-v2:0')
    end
  end

  context 'when no provider is available' do
    before do
      allow(Legion::LLM::Discovery::Ollama).to receive(:model_available?)
        .and_return(false)
      Legion::Settings[:llm][:providers].each_value { |v| v[:enabled] = false }
    end

    it 'sets can_embed? to false' do
      Legion::LLM.send(:detect_embedding_capability)
      expect(Legion::LLM.can_embed?).to be false
      expect(Legion::LLM.embedding_provider).to be_nil
    end
  end
end

RSpec.describe 'Legion::LLM::Embeddings' do
  describe '.generate dimension enforcement' do
    let(:mock_response) do
      double('EmbedResponse',
             vectors: [Array.new(1024, 0.1)],
             input_tokens: 10)
    end

    before do
      allow(RubyLLM).to receive(:embed).and_return(mock_response)
      Legion::LLM.instance_variable_set(:@started, true)
      Legion::LLM.instance_variable_set(:@embedding_provider, :ollama)
      Legion::LLM.instance_variable_set(:@embedding_model, 'mxbai-embed-large')
    end

    it 'returns exactly 1024 dimensions' do
      result = Legion::LLM::Embeddings.generate(text: 'test')
      expect(result[:vector].size).to eq(1024)
      expect(result[:dimensions]).to eq(1024)
    end

    context 'when provider returns wrong dimensions' do
      let(:mock_response) do
        double('EmbedResponse',
               vectors: [Array.new(1536, 0.1)],
               input_tokens: 10)
      end

      it 'truncates to 1024' do
        result = Legion::LLM::Embeddings.generate(text: 'test')
        expect(result[:vector].size).to eq(1024)
      end
    end

    context 'when provider returns fewer dimensions' do
      let(:mock_response) do
        double('EmbedResponse',
               vectors: [Array.new(768, 0.1)],
               input_tokens: 10)
      end

      it 'returns error for incompatible dimension' do
        result = Legion::LLM::Embeddings.generate(text: 'test')
        expect(result[:error]).to include('dimension')
      end
    end
  end

  describe '.generate when LLM not started' do
    before { allow(Legion::LLM).to receive(:started?).and_return(false) }

    it 'returns error without calling RubyLLM' do
      result = Legion::LLM::Embeddings.generate(text: 'test')
      expect(result[:error]).to eq('LLM not started')
      expect(result[:vector]).to be_nil
    end
  end

  describe '.generate with cached provider' do
    before do
      Legion::LLM.instance_variable_set(:@started, true)
      Legion::LLM.instance_variable_set(:@embedding_provider, :ollama)
      Legion::LLM.instance_variable_set(:@embedding_model, 'mxbai-embed-large')
    end

    it 'uses cached provider when no explicit provider given' do
      expect(RubyLLM).to receive(:embed).with('test', hash_including(
                                                         model: 'mxbai-embed-large', provider: :ollama
                                                       )).and_return(double(vectors: [Array.new(1024, 0.1)], input_tokens: 5))

      Legion::LLM::Embeddings.generate(text: 'test')
    end
  end
end

RSpec.describe Legion::LLM::Embeddings do
  before do
    allow(Legion::Settings).to receive(:dig).and_return(nil)
    Legion::LLM.instance_variable_set(:@can_embed, nil)
    Legion::LLM.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM.instance_variable_set(:@embedding_model, nil)
    Legion::LLM.instance_variable_set(:@started, true)
  end

  after do
    Legion::LLM.instance_variable_set(:@started, nil)
  end

  describe '.generate' do
    it 'returns vector hash structure' do
      mock_response = double(vectors: [Array.new(1024, 0.1)], input_tokens: 5)
      allow(RubyLLM).to receive(:embed).and_return(mock_response)

      result = described_class.generate(text: 'hello world')
      expect(result[:vector].size).to eq(1024)
      expect(result[:dimensions]).to eq(1024)
      expect(result[:tokens]).to eq(5)
    end

    it 'handles errors gracefully' do
      allow(RubyLLM).to receive(:embed).and_raise(StandardError.new('provider down'))
      result = described_class.generate(text: 'test')
      expect(result[:vector]).to be_nil
      expect(result[:error]).to include('provider down')
    end

    it 'passes custom model and provider' do
      mock_response = double(vectors: [Array.new(1024, 0.1)], input_tokens: 1)
      allow(RubyLLM).to receive(:embed).with('text', hash_including(model: 'custom-model', provider: :bedrock)).and_return(mock_response)

      result = described_class.generate(text: 'text', model: 'custom-model', provider: :bedrock)
      expect(result[:model]).to eq('custom-model')
      expect(result[:provider]).to eq(:bedrock)
    end

    it 'resolves provider from llm settings when not specified' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :default_provider).and_return(:bedrock)
      allow(Legion::Settings).to receive(:dig).with(:llm, :embedding).and_return(nil)

      mock_response = double(vectors: [Array.new(1024, 0.1)], input_tokens: 1)
      allow(RubyLLM).to receive(:embed).and_return(mock_response)

      result = described_class.generate(text: 'test')
      expect(result[:provider]).to eq(:bedrock)
    end
  end

  describe '.generate_batch' do
    it 'returns array of vectors' do
      mock_response = double(vectors: [Array.new(1024, 0.1), Array.new(1024, 0.2)])
      allow(RubyLLM).to receive(:embed).and_return(mock_response)

      results = described_class.generate_batch(texts: %w[hello world])
      expect(results.size).to eq(2)
      expect(results.first[:vector].size).to eq(1024)
      expect(results.last[:index]).to eq(1)
    end

    it 'handles batch errors gracefully' do
      allow(RubyLLM).to receive(:embed).and_raise(StandardError.new('batch fail'))
      results = described_class.generate_batch(texts: %w[a b])
      expect(results.size).to eq(2)
      expect(results.all? { |r| r[:vector].nil? }).to be true
    end
  end

  describe '.default_model' do
    it 'falls back to text-embedding-3-small when no provider' do
      expect(described_class.default_model).to eq('text-embedding-3-small')
    end

    it 'uses provider_models from embedding settings for bedrock' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :embedding).and_return(
        { provider_models: { bedrock: 'amazon.titan-embed-text-v2:0' } }
      )
      allow(Legion::Settings).to receive(:dig).with(:llm, :default_provider).and_return(:bedrock)
      Legion::LLM.instance_variable_set(:@embedding_provider, :bedrock)
      Legion::LLM.instance_variable_set(:@embedding_model, 'amazon.titan-embed-text-v2:0')
      expect(described_class.default_model).to eq('amazon.titan-embed-text-v2:0')
    end
  end
end
