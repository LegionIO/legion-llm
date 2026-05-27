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

RSpec.describe 'Legion::LLM embedding capability' do
  before do
    Legion::LLM::Discovery.instance_variable_set(:@can_embed, nil)
    Legion::LLM::Discovery.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM::Discovery.instance_variable_set(:@embedding_model, nil)
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
    Legion::LLM::Discovery.instance_variable_set(:@can_embed, nil)
    Legion::LLM::Discovery.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM::Discovery.instance_variable_set(:@embedding_model, nil)
    Legion::LLM::Discovery.instance_variable_set(:@embedding_instance, nil)
    Legion::LLM.instance_variable_set(:@can_embed, nil)
    Legion::LLM.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM.instance_variable_set(:@embedding_model, nil)
    Legion::LLM.instance_variable_set(:@embedding_instance, nil)
  end

  context 'when Registry has instances with embedding capability' do
    before do
      Legion::LLM::Call::Registry.register(
        :ollama,
        Module.new { define_singleton_method(:embed) { |**| nil } },
        instance: :gpu_box,
        metadata: { capabilities: [:embedding], tier: 'local', default_model: 'mxbai-embed-large' }
      )
      Legion::LLM::Discovery.instance_variable_set(
        :@discovered_models_cache,
        [{ provider: :ollama, instance: :gpu_box, model: 'mxbai-embed-large', capabilities: [:embedding] }]
      )
    end

    it 'selects the registry instance as primary embedding provider' do
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM::Discovery.can_embed?).to be true
      expect(Legion::LLM::Discovery.embedding_provider).to eq(:ollama)
      expect(Legion::LLM::Discovery.embedding_model).to eq('mxbai-embed-large')
      expect(Legion::LLM::Discovery.embedding_instance).to eq(:gpu_box)
    end

    it 'exposes embedding_instance through the LLM facade' do
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM.embedding_instance).to eq(:gpu_box)
    end

    it 'builds a fallback chain from registry instances' do
      Legion::LLM::Discovery.detect_embedding_capability
      chain = Legion::LLM::Discovery.embedding_fallback_chain
      expect(chain).to be_an(Array)
      expect(chain.first[:provider]).to eq(:ollama)
      expect(chain.first[:instance]).to eq(:gpu_box)
    end

    it 'does not fall through to ollama model scanning' do
      expect(Legion::LLM::Discovery).not_to receive(:find_embedding_provider)
      Legion::LLM::Discovery.detect_embedding_capability
    end
  end

  context 'when Registry has multiple embedding instances across tiers' do
    before do
      Legion::LLM::Call::Registry.register(
        :bedrock,
        Module.new { define_singleton_method(:embed) { |**| nil } },
        instance: :default,
        metadata: { capabilities: [:embedding], tier: 'cloud', default_model: 'amazon.titan-embed-text-v2:0' }
      )
      Legion::LLM::Call::Registry.register(
        :ollama,
        Module.new { define_singleton_method(:embed) { |**| nil } },
        instance: :local_box,
        metadata: { capabilities: [:embedding], tier: 'local', default_model: 'mxbai-embed-large' }
      )
      Legion::LLM::Call::Registry.register(
        :vllm,
        Module.new { define_singleton_method(:embed) { |**| nil } },
        instance: :fleet_gpu,
        metadata: { capabilities: [:embedding], tier: 'fleet', default_model: 'bge-large' }
      )
      Legion::LLM::Discovery.instance_variable_set(
        :@discovered_models_cache,
        [
          { provider: :ollama, instance: :local_box, model: 'mxbai-embed-large', capabilities: [:embedding] },
          { provider: :vllm, instance: :fleet_gpu, model: 'bge-large', capabilities: [:embedding] },
          { provider: :bedrock, instance: :default, model: 'amazon.titan-embed-text-v2:0', capabilities: [:embedding] }
        ]
      )
    end

    it 'picks the best tier (local) over cloud and fleet' do
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM::Discovery.embedding_provider).to eq(:ollama)
      expect(Legion::LLM::Discovery.embedding_instance).to eq(:local_box)
      expect(Legion::LLM::Discovery.embedding_model).to eq('mxbai-embed-large')
    end

    it 'orders the fallback chain by tier priority' do
      Legion::LLM::Discovery.detect_embedding_capability
      tiers = Legion::LLM::Discovery.embedding_fallback_chain.map { |e| e[:provider] }
      expect(tiers).to eq(%i[ollama vllm bedrock])
    end
  end

  context 'when Registry has embedding instances but no default_model in metadata' do
    before do
      Legion::LLM::Call::Registry.register(
        :openai,
        Module.new { define_singleton_method(:embed) { |**| nil } },
        instance: :default,
        metadata: { capabilities: [:embedding], tier: 'frontier' }
      )
    end

    it 'falls back to Settings embedding default_model' do
      Legion::Settings[:llm][:embedding][:default_model] = 'text-embedding-3-small'
      Legion::LLM::Discovery.instance_variable_set(
        :@discovered_models_cache,
        [{ provider: :openai, instance: :default, model: 'text-embedding-3-small', capabilities: [:embedding] }]
      )
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM::Discovery.embedding_model).to eq('text-embedding-3-small')
    end

    it 'falls back to discovered model catalog when Settings has no default_model (#121)' do
      Legion::LLM::Discovery.instance_variable_set(
        :@discovered_models_cache,
        [{ provider: :openai, instance: :default, model: 'text-embedding-ada-002', capabilities: [:embedding] }]
      )
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM::Discovery.can_embed?).to be true
      expect(Legion::LLM::Discovery.embedding_model).to eq('text-embedding-ada-002')
    end

    it 'returns false and does not set can_embed when no model is resolvable (#121)' do
      Legion::LLM::Discovery.instance_variable_set(:@discovered_models_cache, [])
      Legion::LLM::Discovery.detect_embedding_capability
      # No model in metadata, settings, or catalog → falls through to legacy probe
      expect(Legion::LLM::Discovery.can_embed?).to be false
    end
  end

  context 'when Registry has no embedding-capable instances' do
    before do
      Legion::LLM::Call::Registry.register(
        :anthropic,
        Module.new { define_singleton_method(:chat) { |**| nil } },
        instance: :default,
        metadata: { capabilities: [:chat], tier: 'frontier' }
      )
    end

    it 'falls through to the legacy provider fallback detection' do
      allow(Legion::LLM::Discovery).to receive(:model_available?).and_return(false)
      Legion::LLM::Discovery.detect_embedding_capability
      # No embedding instances in registry, no ollama models => can_embed? is false
      expect(Legion::LLM::Discovery.can_embed?).to be false
      expect(Legion::LLM::Discovery.embedding_instance).to be_nil
    end
  end

  context 'when Registry.with_capability raises an error' do
    before do
      allow(Legion::LLM::Call::Registry).to receive(:with_capability)
        .and_raise(StandardError.new('registry broken'))
    end

    it 'falls through to legacy detection without raising' do
      allow(Legion::LLM::Discovery).to receive(:model_available?).and_return(false)
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM::Discovery.can_embed?).to be false
    end
  end

  context 'when Ollama has a preferred model' do
    before do
      Legion::Settings[:extensions][:llm][:ollama] = { enabled: true, base_url: 'http://localhost:11434' }
      allow(Legion::LLM::Discovery).to receive(:model_available?)
        .and_return(false)
      allow(Legion::LLM::Discovery).to receive(:model_available?)
        .with('mxbai-embed-large', provider: :ollama).and_return(true)
    end

    it 'selects Ollama with that model' do
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be true
      expect(Legion::LLM.embedding_provider).to eq(:ollama)
      expect(Legion::LLM.embedding_model).to eq('mxbai-embed-large')
    end
  end

  context 'when embedding settings use deprecated plural "embeddings" key (#124)' do
    before do
      Legion::Settings[:extensions][:llm][:ollama] = { enabled: true, base_url: 'http://localhost:11434' }
      Legion::Settings[:llm].delete(:embedding)
      Legion::Settings[:llm][:embeddings] = {
        provider_fallback: %w[ollama],
        ollama_preferred:  %w[nomic-embed-text]
      }
      allow(Legion::LLM::Discovery).to receive(:model_available?)
        .and_return(false)
      allow(Legion::LLM::Discovery).to receive(:model_available?)
        .with('nomic-embed-text', provider: :ollama).and_return(true)
    end

    it 'reads embedding settings from plural key with deprecation warning' do
      expect(Legion::LLM::Discovery.log).to receive(:warn).with(/deprecated/).at_least(:once)
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be true
      expect(Legion::LLM.embedding_model).to eq('nomic-embed-text')
    end
  end

  context 'when embedding discovery settings were loaded from JSON string keys' do
    before do
      Legion::Settings[:extensions][:llm] = {
        'ollama' => { 'enabled' => true }
      }
      Legion::Settings[:llm]['embedding'] = {
        'provider_fallback' => %w[ollama],
        'ollama_preferred'  => %w[nomic-embed-text]
      }
      allow(Legion::LLM::Discovery).to receive(:model_available?)
        .and_return(false)
      allow(Legion::LLM::Discovery).to receive(:model_available?)
        .with('nomic-embed-text', provider: :ollama).and_return(true)
    end

    it 'uses string-keyed embedding fallback and model preference settings' do
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be true
      expect(Legion::LLM.embedding_provider).to eq(:ollama)
      expect(Legion::LLM.embedding_model).to eq('nomic-embed-text')
    end
  end

  context 'when Ollama has no models and bedrock health check fails, falls back to openai' do
    before do
      allow(Legion::LLM::Discovery).to receive(:model_available?)
        .and_return(false)
      Legion::Settings[:extensions][:llm][:bedrock] = { enabled: true, default_model: 'us.anthropic.claude-sonnet-4-6-v1' }
      Legion::Settings[:extensions][:llm][:openai] = { enabled: true, default_model: 'gpt-4o' }
      allow(Legion::LLM::Discovery).to receive(:verify_embedding).with(:bedrock, anything).and_return(false)
      allow(Legion::LLM::Discovery).to receive(:verify_embedding).with(:openai, 'text-embedding-3-small').and_return(true)
    end

    it 'skips bedrock on health-check failure and falls back to openai' do
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be true
      expect(Legion::LLM.embedding_provider).to eq(:openai)
      expect(Legion::LLM.embedding_model).to eq('text-embedding-3-small')
    end
  end

  context 'when only bedrock is configured and its health check passes' do
    before do
      allow(Legion::LLM::Discovery).to receive(:model_available?)
        .and_return(false)
      Legion::Settings[:extensions][:llm][:bedrock] = { enabled: true, default_model: 'us.anthropic.claude-sonnet-4-6-v1' }
      allow(Legion::LLM::Discovery).to receive(:verify_embedding).with(:bedrock, anything).and_return(true)
    end

    it 'selects bedrock with the Titan v2 model' do
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be true
      expect(Legion::LLM.embedding_provider).to eq(:bedrock)
      expect(Legion::LLM.embedding_model).to eq('amazon.titan-embed-text-v2:0')
    end
  end

  context 'when only bedrock is configured and its health check fails' do
    before do
      allow(Legion::LLM::Discovery).to receive(:model_available?)
        .and_return(false)
      Legion::Settings[:extensions][:llm][:bedrock] = { enabled: true, default_model: 'us.anthropic.claude-sonnet-4-6-v1' }
      allow(Legion::LLM::Discovery).to receive(:verify_embedding).with(:bedrock, anything).and_return(false)
    end

    it 'leaves embeddings unavailable' do
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be false
      expect(Legion::LLM.embedding_provider).to be_nil
    end
  end

  context 'when no provider is available' do
    before do
      allow(Legion::LLM::Discovery).to receive(:model_available?)
        .and_return(false)
      Legion::Settings[:extensions][:llm].each_value { |v| v[:enabled] = false }
    end

    it 'sets can_embed? to false' do
      Legion::LLM::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be false
      expect(Legion::LLM.embedding_provider).to be_nil
    end
  end
end

RSpec.describe 'Legion::LLM::Embeddings' do
  describe '.generate calls Dispatch.call(capability: :embed)' do
    before do
      Legion::LLM.instance_variable_set(:@started, true)
      Legion::LLM.instance_variable_set(:@embedding_provider, :openai)
      Legion::LLM.instance_variable_set(:@embedding_model, 'text-embedding-3-small')
    end

    it 'dispatches through Dispatch.call with capability: :embed' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call).with(
        provider:   :openai,
        instance:   nil,
        capability: :embed,
        model:      'text-embedding-3-small',
        text:       'test',
        dimensions: nil
      ).and_return(native_embed_response)

      result = Legion::LLM::Embeddings.generate(text: 'test')
      expect(result[:vector]).to be_a(Array)
      expect(result[:vector].size).to eq(1024)
      expect(result[:provider]).to eq(:openai)
    end

    it 'passes custom model, provider, and instance' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call).with(
        provider:   :bedrock,
        instance:   :us_west,
        capability: :embed,
        model:      'custom-model',
        text:       'text',
        dimensions: 512
      ).and_return(native_embed_response)

      result = Legion::LLM::Embeddings.generate(
        text: 'text', model: 'custom-model', provider: :bedrock,
        instance: :us_west, dimensions: 512
      )
      expect(result[:model]).to eq('custom-model')
      expect(result[:provider]).to eq(:bedrock)
    end

    it 'chunks oversized Ollama embedding input before provider dispatch' do
      Legion::LLM.instance_variable_set(:@embedding_provider, :ollama)
      Legion::LLM.instance_variable_set(:@embedding_model, 'mxbai-embed-large')
      Legion::Settings[:llm][:embedding][:ollama_context_chars]['mxbai-embed-large'] = 10

      expect(Legion::LLM::Call::Dispatch).to receive(:call).with(
        hash_including(
          provider: :ollama,
          model:    'mxbai-embed-large',
          text:     [('a' * 10), ('a' * 10), ('a' * 10)]
        )
      ).and_return(
        native_embed_response(
          vectors:      [
            Array.new(1024, 1.0),
            Array.new(1024, 3.0),
            Array.new(1024, 5.0)
          ],
          input_tokens: 30
        )
      )

      result = Legion::LLM::Embeddings.generate(text: 'a' * 30)

      expect(result[:vector].first).to eq(3.0)
      expect(result[:chunks]).to eq(3)
      expect(result[:tokens]).to eq(30)
    end
  end

  describe '.generate dimension enforcement' do
    before do
      allow(Legion::LLM::Call::Dispatch).to receive(:call).and_return(native_embed_response)
      Legion::LLM.instance_variable_set(:@started, true)
      Legion::LLM.instance_variable_set(:@embedding_provider, :openai)
      Legion::LLM.instance_variable_set(:@embedding_model, 'text-embedding-3-small')
    end

    it 'returns exactly 1024 dimensions' do
      result = Legion::LLM::Embeddings.generate(text: 'test')
      expect(result[:vector].size).to eq(1024)
      expect(result[:dimensions]).to eq(1024)
    end

    context 'when provider returns wrong dimensions' do
      it 'truncates to 1024' do
        allow(Legion::LLM::Call::Dispatch).to receive(:call)
          .and_return(native_embed_response(vectors: [Array.new(1536, 0.1)]))

        result = Legion::LLM::Embeddings.generate(text: 'test')
        expect(result[:vector].size).to eq(1024)
      end
    end

    context 'when provider returns fewer dimensions' do
      it 'returns the vector as-is (no upscale)' do
        allow(Legion::LLM::Call::Dispatch).to receive(:call)
          .and_return(native_embed_response(vectors: [Array.new(768, 0.1)]))

        result = Legion::LLM::Embeddings.generate(text: 'test')
        expect(result[:vector].size).to eq(768)
      end
    end
  end

  describe '.generate when LLM not started' do
    before { allow(Legion::LLM).to receive(:started?).and_return(false) }

    it 'returns error without dispatching' do
      expect(Legion::LLM::Call::Dispatch).not_to receive(:call)

      result = Legion::LLM::Embeddings.generate(text: 'test')
      expect(result[:error]).to eq('LLM not started')
      expect(result[:vector]).to be_nil
    end
  end

  describe '.generate when no provider configured' do
    before do
      Legion::LLM.instance_variable_set(:@started, true)
      Legion::LLM.instance_variable_set(:@embedding_provider, nil)
      Legion::LLM.instance_variable_set(:@embedding_model, nil)
    end

    it 'returns error without dispatching' do
      expect(Legion::LLM::Call::Dispatch).not_to receive(:call)

      result = Legion::LLM::Embeddings.generate(text: 'test')
      expect(result[:error]).to eq('No embedding provider configured')
      expect(result[:vector]).to be_nil
    end
  end

  describe '.generate error handling' do
    before do
      Legion::LLM.instance_variable_set(:@started, true)
      Legion::LLM.instance_variable_set(:@embedding_provider, :openai)
      Legion::LLM.instance_variable_set(:@embedding_model, 'text-embedding-3-small')
    end

    it 'returns error hash on dispatch failure' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_raise(StandardError.new('provider down'))

      result = Legion::LLM::Embeddings.generate(text: 'test')
      expect(result[:vector]).to be_nil
      expect(result[:error]).to include('provider down')
    end
  end

  describe '.generate prefix injection' do
    before do
      Legion::LLM.instance_variable_set(:@started, true)
      Legion::LLM.instance_variable_set(:@embedding_provider, :ollama)
      Legion::LLM.instance_variable_set(:@embedding_model, 'nomic-embed-text')
    end

    it 'prepends search_document prefix for nomic model' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call).with(
        hash_including(text: 'search_document: hello world')
      ).and_return(native_embed_response)

      Legion::LLM::Embeddings.generate(text: 'hello world', task: :document)
    end

    it 'prepends search_query prefix for nomic model with query task' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call).with(
        hash_including(text: 'search_query: hello world')
      ).and_return(native_embed_response)

      Legion::LLM::Embeddings.generate(text: 'hello world', task: :query)
    end

    it 'prepends prefix for mxbai model with query task' do
      Legion::LLM.instance_variable_set(:@embedding_model, 'mxbai-embed-large')

      expect(Legion::LLM::Call::Dispatch).to receive(:call).with(
        hash_including(text: 'Represent this sentence for searching relevant passages: hello')
      ).and_return(native_embed_response)

      Legion::LLM::Embeddings.generate(text: 'hello', task: :query)
    end

    it 'does not prefix for unknown models' do
      Legion::LLM.instance_variable_set(:@embedding_model, 'text-embedding-3-small')
      Legion::LLM.instance_variable_set(:@embedding_provider, :openai)

      expect(Legion::LLM::Call::Dispatch).to receive(:call).with(
        hash_including(text: 'hello')
      ).and_return(native_embed_response)

      Legion::LLM::Embeddings.generate(text: 'hello')
    end
  end

  describe '.generate text coercion' do
    before do
      Legion::LLM.instance_variable_set(:@started, true)
      Legion::LLM.instance_variable_set(:@embedding_provider, :openai)
      Legion::LLM.instance_variable_set(:@embedding_model, 'text-embedding-3-small')
    end

    it 'passes strings through unchanged' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call).with(
        hash_including(text: 'hello world')
      ).and_return(native_embed_response)

      Legion::LLM::Embeddings.generate(text: 'hello world')
    end

    it 'flattens structured text blocks from arrays' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call).with(
        hash_including(text: 'what tools are available to you?')
      ).and_return(native_embed_response)

      Legion::LLM::Embeddings.generate(text: [{ type: 'text', text: 'what tools are available to you?' }])
    end

    it 'extracts text from Hash input' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call).with(
        hash_including(text: 'from hash')
      ).and_return(native_embed_response)

      Legion::LLM::Embeddings.generate(text: { text: 'from hash' })
    end
  end

  describe '.generate token extraction' do
    before do
      Legion::LLM.instance_variable_set(:@started, true)
      Legion::LLM.instance_variable_set(:@embedding_provider, :openai)
      Legion::LLM.instance_variable_set(:@embedding_model, 'text-embedding-3-small')
    end

    it 'extracts tokens from Usage object' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_return(native_embed_response(input_tokens: 42))

      result = Legion::LLM::Embeddings.generate(text: 'test')
      expect(result[:tokens]).to eq(42)
    end

    it 'extracts tokens from hash usage' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_return({ result: [Array.new(1024, 0.1)], usage: { input_tokens: 7 } })

      result = Legion::LLM::Embeddings.generate(text: 'test')
      expect(result[:tokens]).to eq(7)
    end

    it 'defaults to 0 when no usage present' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_return({ result: [Array.new(1024, 0.1)], usage: nil })

      result = Legion::LLM::Embeddings.generate(text: 'test')
      expect(result[:tokens]).to eq(0)
    end
  end
end

RSpec.describe Legion::LLM::Embeddings do
  before do
    allow(Legion::Settings).to receive(:dig).and_return(nil)
    Legion::LLM.instance_variable_set(:@can_embed, nil)
    Legion::LLM.instance_variable_set(:@embedding_provider, :openai)
    Legion::LLM.instance_variable_set(:@embedding_model, 'text-embedding-3-small')
    Legion::LLM.instance_variable_set(:@started, true)
  end

  after do
    Legion::LLM.instance_variable_set(:@started, nil)
  end

  describe '.generate' do
    it 'returns vector hash structure' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call).and_return(native_embed_response)

      result = described_class.generate(text: 'hello world')
      expect(result[:vector].size).to eq(1024)
      expect(result[:dimensions]).to eq(1024)
      expect(result[:tokens]).to eq(5)
    end

    it 'handles errors gracefully' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call).and_raise(StandardError.new('provider down'))
      result = described_class.generate(text: 'test')
      expect(result[:vector]).to be_nil
      expect(result[:error]).to include('provider down')
    end

    it 'handles unwrapped vectors from providers that flatten single-input results' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_return({ result: Array.new(1024, 0.1), usage: Legion::LLM::Usage.new(input_tokens: 5) })

      result = described_class.generate(text: 'test')
      expect(result[:vector]).to be_a(Array)
      expect(result[:vector].size).to eq(1024)
      expect(result[:dimensions]).to eq(1024)
    end

    it 'does not resolve provider from chat default_provider when not specified' do
      Legion::Settings[:llm][:default_provider] = :bedrock
      Legion::LLM.instance_variable_set(:@embedding_provider, nil)
      Legion::LLM.instance_variable_set(:@embedding_model, nil)

      expect(Legion::LLM::Call::Dispatch).not_to receive(:call)

      result = described_class.generate(text: 'test')
      expect(result[:provider]).to be_nil
      expect(result[:error]).to eq('No embedding provider configured')
    end

    it 'does not route embeddings to vllm when vllm is the chat default provider' do
      Legion::Settings[:llm][:default_provider] = :vllm
      Legion::LLM.instance_variable_set(:@embedding_provider, nil)
      Legion::LLM.instance_variable_set(:@embedding_model, nil)

      expect(Legion::LLM::Call::Dispatch).not_to receive(:call)

      result = described_class.generate(text: 'test')
      expect(result[:provider]).to be_nil
      expect(result[:error]).to eq('No embedding provider configured')
    end
  end

  describe '.generate_batch' do
    it 'calls Dispatch.call with capability: :embed for batch' do
      batch_vectors = [Array.new(1024, 0.1), Array.new(1024, 0.2)]
      allow(Legion::LLM::Call::Dispatch).to receive(:call)
        .and_return({ result: batch_vectors, usage: Legion::LLM::Usage.new(input_tokens: 10) })

      results = described_class.generate_batch(texts: %w[hello world])
      expect(results.size).to eq(2)
      expect(results.first[:vector].size).to eq(1024)
      expect(results.last[:index]).to eq(1)
    end

    it 'chunks oversized batch entries without sending oversized array inputs to the provider' do
      Legion::LLM.instance_variable_set(:@embedding_provider, :ollama)
      Legion::LLM.instance_variable_set(:@embedding_model, 'mxbai-embed-large')
      Legion::Settings[:llm][:embedding][:ollama_context_chars]['mxbai-embed-large'] = 10

      dispatched_texts = []
      allow(Legion::LLM::Call::Dispatch).to receive(:call) do |args|
        dispatched_texts << args[:text]
        if args[:text].is_a?(Array)
          native_embed_response(
            vectors:      args[:text].each_index.map { |index| Array.new(1024, index + 1.0) },
            input_tokens: 30
          )
        else
          native_embed_response(vectors: [Array.new(1024, 0.5)], input_tokens: 1)
        end
      end

      results = described_class.generate_batch(texts: ['short', 'b' * 30])

      expect(dispatched_texts).to eq(['short', [('b' * 10), ('b' * 10), ('b' * 10)]])
      expect(results.size).to eq(2)
      expect(results.first[:index]).to eq(0)
      expect(results.last[:index]).to eq(1)
      expect(results.last[:chunks]).to eq(3)
    end

    it 'handles batch errors gracefully' do
      allow(Legion::LLM::Call::Dispatch).to receive(:call).and_raise(StandardError.new('batch fail'))
      results = described_class.generate_batch(texts: %w[a b])
      expect(results.size).to eq(2)
      expect(results.all? { |r| r[:vector].nil? }).to be true
    end

    it 'returns not-started errors when LLM not started' do
      Legion::LLM.instance_variable_set(:@started, false)
      allow(Legion::LLM).to receive(:started?).and_return(false)

      results = described_class.generate_batch(texts: %w[a b c])
      expect(results.size).to eq(3)
      expect(results.all? { |r| r[:error] == 'LLM not started' }).to be true
    end
  end

  describe '.default_model' do
    it 'returns the cached embedding model' do
      expect(described_class.default_model).to eq('text-embedding-3-small')
    end

    it 'falls back to Settings value when no cached model' do
      Legion::LLM.instance_variable_set(:@embedding_model, nil)
      Legion::Settings[:llm][:embedding][:default_model] = 'amazon.titan-embed-text-v2:0'
      expect(described_class.default_model).to eq('amazon.titan-embed-text-v2:0')
    end

    context 'plural embeddings key back-compat (#124)' do
      before do
        Legion::LLM.instance_variable_set(:@embedding_model, nil)
        Legion::LLM.instance_variable_set(:@embedding_provider, nil)
        Legion::Settings[:llm].delete(:embedding)
        Legion::Settings[:llm][:embeddings] = { default_model: 'nomic-embed-text', provider: 'ollama' }
      end

      it 'reads default_model from plural embeddings key with deprecation warning' do
        expect(described_class).to receive(:log).at_least(:once).and_return(
          double('log', warn: nil, debug: nil, info: nil)
        )
        expect(described_class.default_model).to eq('nomic-embed-text')
      end

      it 'reads provider from plural embeddings key' do
        allow(described_class).to receive(:log).and_return(double('log', warn: nil, debug: nil, info: nil))
        expect(described_class.send(:resolve_provider)).to eq(:ollama)
      end
    end
  end
end
