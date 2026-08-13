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
    Legion::LLM::Inventory::Discovery.instance_variable_set(:@can_embed, nil)
    Legion::LLM::Inventory::Discovery.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM::Inventory::Discovery.instance_variable_set(:@embedding_model, nil)
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
    Legion::LLM::Inventory::Discovery.instance_variable_set(:@can_embed, nil)
    Legion::LLM::Inventory::Discovery.instance_variable_set(:@embedding_provider, nil)
    Legion::LLM::Inventory::Discovery.instance_variable_set(:@embedding_model, nil)
    Legion::LLM::Inventory::Discovery.instance_variable_set(:@embedding_instance, nil)
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
      Legion::LLM::Inventory.write_lane(lane: {
                                          id: 'local:ollama:gpu_box:embed:mxbai-embed-large', tier: :local,
        provider_family: :ollama, instance_id: :gpu_box, model: 'mxbai-embed-large',
        type: :embed, capabilities: %i[embedding], limits: {}, enabled: true, cost: {}
                                        })
    end

    it 'selects the registry instance as primary embedding provider' do
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      expect(Legion::LLM::Inventory::Discovery.can_embed?).to be true
      expect(Legion::LLM::Inventory::Discovery.embedding_provider).to eq(:ollama)
      expect(Legion::LLM::Inventory::Discovery.embedding_model).to eq('mxbai-embed-large')
      expect(Legion::LLM::Inventory::Discovery.embedding_instance).to eq(:gpu_box)
    end

    it 'exposes embedding_instance through the LLM facade' do
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      expect(Legion::LLM.embedding_instance).to eq(:gpu_box)
    end

    it 'builds a fallback chain from registry instances' do
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      chain = Legion::LLM::Inventory::Discovery.embedding_fallback_chain
      expect(chain).to be_an(Array)
      expect(chain.first[:provider]).to eq(:ollama)
      expect(chain.first[:instance]).to eq(:gpu_box)
    end

    it 'does not fall through to ollama model scanning' do
      expect(Legion::LLM::Inventory::Discovery).not_to receive(:find_embedding_provider)
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
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
      Legion::LLM::Inventory.write_lane(lane: {
                                          id: 'local:ollama:local_box:embed:mxbai-embed-large', tier: :local,
        provider_family: :ollama, instance_id: :local_box, model: 'mxbai-embed-large',
        type: :embed, capabilities: %i[embedding], limits: {}, enabled: true, cost: {}
                                        })
      Legion::LLM::Inventory.write_lane(lane: {
                                          id: 'fleet:vllm:fleet_gpu:embed:bge-large', tier: :fleet,
        provider_family: :vllm, instance_id: :fleet_gpu, model: 'bge-large',
        type: :embed, capabilities: %i[embedding], limits: {}, enabled: true, cost: {}
                                        })
      Legion::LLM::Inventory.write_lane(lane: {
                                          id: 'cloud:bedrock:default:embed:amazon.titan-embed-text-v2_0', tier: :cloud,
        provider_family: :bedrock, instance_id: :default, model: 'amazon.titan-embed-text-v2:0',
        type: :embed, capabilities: %i[embedding], limits: {}, enabled: true, cost: {}
                                        })
    end

    it 'picks the best tier (local) over cloud and fleet' do
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      expect(Legion::LLM::Inventory::Discovery.embedding_provider).to eq(:ollama)
      expect(Legion::LLM::Inventory::Discovery.embedding_instance).to eq(:local_box)
      expect(Legion::LLM::Inventory::Discovery.embedding_model).to eq('mxbai-embed-large')
    end

    it 'orders the fallback chain by tier priority' do
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      tiers = Legion::LLM::Inventory::Discovery.embedding_fallback_chain.map { |e| e[:provider] }
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
      Legion::LLM::Inventory.write_lane(lane: {
                                          id: 'frontier:openai:default:embed:text-embedding-3-small', tier: :frontier,
        provider_family: :openai, instance_id: :default, model: 'text-embedding-3-small',
        type: :embed, capabilities: %i[embedding], limits: {}, enabled: true, cost: {}
                                        })
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      expect(Legion::LLM::Inventory::Discovery.embedding_model).to eq('text-embedding-3-small')
    end

    it 'falls back to discovered model catalog when Settings has no default_model (#121)' do
      Legion::LLM::Inventory.write_lane(lane: {
                                          id: 'frontier:openai:default:embed:text-embedding-ada-002', tier: :frontier,
        provider_family: :openai, instance_id: :default, model: 'text-embedding-ada-002',
        type: :embed, capabilities: %i[embedding], limits: {}, enabled: true, cost: {}
                                        })
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      expect(Legion::LLM::Inventory::Discovery.can_embed?).to be true
      expect(Legion::LLM::Inventory::Discovery.embedding_model).to eq('text-embedding-ada-002')
    end

    it 'returns false and does not set can_embed when no model is resolvable (#121)' do
      # No lanes written — model_available? returns false → can_embed? = false
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      # No model in metadata, settings, or catalog → falls through to legacy probe
      expect(Legion::LLM::Inventory::Discovery.can_embed?).to be false
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
      allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?).and_return(false)
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      # No embedding instances in registry, no ollama models => can_embed? is false
      expect(Legion::LLM::Inventory::Discovery.can_embed?).to be false
      expect(Legion::LLM::Inventory::Discovery.embedding_instance).to be_nil
    end
  end

  context 'when Registry.with_capability raises an error' do
    before do
      allow(Legion::LLM::Call::Registry).to receive(:with_capability)
        .and_raise(StandardError.new('registry broken'))
    end

    it 'falls through to legacy detection without raising' do
      allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?).and_return(false)
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      expect(Legion::LLM::Inventory::Discovery.can_embed?).to be false
    end
  end

  context 'when Ollama has a preferred model' do
    before do
      Legion::Settings[:extensions][:llm][:ollama] = { enabled: true, base_url: 'http://localhost:11434' }
      allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?)
        .and_return(false)
      allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?)
        .with('mxbai-embed-large', provider: :ollama).and_return(true)
    end

    it 'selects Ollama with that model' do
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be true
      expect(Legion::LLM.embedding_provider).to eq(:ollama)
      expect(Legion::LLM.embedding_model).to eq('mxbai-embed-large')
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
      allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?)
        .and_return(false)
      allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?)
        .with('nomic-embed-text', provider: :ollama).and_return(true)
    end

    it 'uses string-keyed embedding fallback and model preference settings' do
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be true
      expect(Legion::LLM.embedding_provider).to eq(:ollama)
      expect(Legion::LLM.embedding_model).to eq('nomic-embed-text')
    end
  end

  context 'when Ollama has no models and bedrock health check fails, falls back to openai' do
    before do
      allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?)
        .and_return(false)
      Legion::Settings[:extensions][:llm][:bedrock] = { enabled: true, default_model: 'us.anthropic.claude-sonnet-4-6-v1' }
      Legion::Settings[:extensions][:llm][:openai] = { enabled: true, default_model: 'gpt-4o' }
      allow(Legion::LLM::Inventory::Discovery).to receive(:verify_embedding).with(:bedrock, anything).and_return(false)
      allow(Legion::LLM::Inventory::Discovery).to receive(:verify_embedding).with(:openai, 'text-embedding-3-small').and_return(true)
    end

    it 'skips bedrock on health-check failure and falls back to openai' do
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be true
      expect(Legion::LLM.embedding_provider).to eq(:openai)
      expect(Legion::LLM.embedding_model).to eq('text-embedding-3-small')
    end
  end

  context 'when only bedrock is configured and its health check passes' do
    before do
      allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?)
        .and_return(false)
      Legion::Settings[:extensions][:llm][:bedrock] = { enabled: true, default_model: 'us.anthropic.claude-sonnet-4-6-v1' }
      allow(Legion::LLM::Inventory::Discovery).to receive(:verify_embedding).with(:bedrock, anything).and_return(true)
    end

    it 'selects bedrock with the Titan v2 model' do
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be true
      expect(Legion::LLM.embedding_provider).to eq(:bedrock)
      expect(Legion::LLM.embedding_model).to eq('amazon.titan-embed-text-v2:0')
    end
  end

  context 'when only bedrock is configured and its health check fails' do
    before do
      allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?)
        .and_return(false)
      Legion::Settings[:extensions][:llm][:bedrock] = { enabled: true, default_model: 'us.anthropic.claude-sonnet-4-6-v1' }
      allow(Legion::LLM::Inventory::Discovery).to receive(:verify_embedding).with(:bedrock, anything).and_return(false)
    end

    it 'leaves embeddings unavailable' do
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be false
      expect(Legion::LLM.embedding_provider).to be_nil
    end
  end

  context 'when no provider is available' do
    before do
      allow(Legion::LLM::Inventory::Discovery).to receive(:model_available?)
        .and_return(false)
      Legion::Settings[:extensions][:llm].each_value { |v| v[:enabled] = false }
    end

    it 'sets can_embed? to false' do
      Legion::LLM::Inventory::Discovery.detect_embedding_capability
      expect(Legion::LLM.can_embed?).to be false
      expect(Legion::LLM.embedding_provider).to be_nil
    end
  end
end

# SSOT v3 §21: Call::Embeddings selects ONE exact lane via Router.next_lane
# (through a per-call RoutingSession) and dispatches the offering's exact callable
# via Call::SelectionDispatch. No request_lane, no Call::Dispatch, no configured
# default model/provider/instance. An omitted model is an unconstrained selection.
RSpec.describe Legion::LLM::Call::Embeddings, :ssot_v3 do
  let(:seed) { 'ab' * 16 }

  before { Legion::LLM.instance_variable_set(:@started, true) }
  after  { Legion::LLM.instance_variable_set(:@started, nil) }

  # Publish an embed offering into the Phase 1 Registry. The callable records the
  # embed arguments it receives and, by default, echoes one 1024-d vector per
  # input with a fixed token count. Pass a block to override the response.
  def publish_embed(model: 'text-embedding-3-small', provider: 'openai', instance: 'primary',
                    tier: :frontier, dims: [1024], context: 200_000, input_tokens: 5, &responder)
    @dispatched ||= []
    responder ||= lambda do |_op, _args, kwargs, _block|
      @dispatched << kwargs
      texts = kwargs[:text]
      vectors = texts.is_a?(Array) ? texts.map { Array.new(1024, 0.1) } : [Array.new(1024, 0.1)]
      { result: vectors, usage: Legion::LLM::Usage.new(input_tokens: input_tokens) }
    end
    activate(
      provider_family: provider, instance_id: instance,
      callable: SsotV3SnapshotFactory::FactoryCallable.new(responder: responder),
      drafts: [offering_draft(model: model, tier: tier, supported: %i[embed],
                              capabilities: { embedding: :supported },
                              embedding_dimensions: dims, context: context)]
    )
  end

  describe '.generate exact selection + dispatch' do
    it 'dispatches the selected lane callable (never Call::Dispatch)' do
      expect(defined?(Legion::LLM::Call::Dispatch) ? Legion::LLM::Call::Dispatch : nil).not_to receive(:call) if defined?(Legion::LLM::Call::Dispatch)
      publish_embed
      result = described_class.generate(text: 'test', model: 'text-embedding-3-small', routing_seed: seed)
      expect(result[:vector]).to be_a(Array)
      expect(result[:vector].size).to eq(1024)
      expect(result[:provider]).to eq(:openai)
      expect(result[:model]).to eq('text-embedding-3-small')
    end

    it 'selects only the pinned model when a model is supplied' do
      publish_embed(model: 'text-embedding-3-small', provider: 'openai', instance: 'primary')
      publish_embed(model: 'other-embed-model', provider: 'bedrock', instance: 'usw2', tier: :cloud)
      result = described_class.generate(text: 'test', model: 'other-embed-model', routing_seed: seed)
      expect(result[:model]).to eq('other-embed-model')
      expect(result[:provider]).to eq(:bedrock)
    end

    it 'selects an embedding-capable lane when no model is pinned (unconstrained, not a default)' do
      publish_embed(model: 'the-only-embed', provider: 'ollama', instance: 'gpu1', tier: :local)
      result = described_class.generate(text: 'test', routing_seed: seed)
      expect(result[:model]).to eq('the-only-embed')
      expect(result[:provider]).to eq(:ollama)
    end
  end

  describe '.generate does not invent a default model' do
    it 'never reads :llm, :embedding, :default_model for selection' do
      Legion::Settings[:llm][:embedding][:default_model] = 'settings-default-embed'
      # No lane for that model is published, so if it were used selection would
      # succeed; instead the unconstrained request finds nothing -> RoutingRejected.
      expect { described_class.generate(text: 'test', routing_seed: seed) }
        .to raise_error(Legion::LLM::Errors::RoutingRejected)
    end

    it 'is unaffected by the chat default_provider' do
      Legion::Settings[:llm][:default_provider] = :vllm
      publish_embed(model: 'real-embed', provider: 'openai', instance: 'primary')
      result = described_class.generate(text: 'test', routing_seed: seed)
      expect(result[:provider]).to eq(:openai)
    end
  end

  describe '.generate dimension matching (§9.7 step 6)' do
    it 'selects an offering that publishes the requested dimension' do
      publish_embed(model: 'dims-model', dims: [512, 1024])
      result = described_class.generate(text: 'test', model: 'dims-model', dimensions: 512, routing_seed: seed)
      expect(result[:dimensions]).to eq(512)
    end

    it 'rejects (context_rejected) when the requested dimension is not published' do
      publish_embed(model: 'dims-model', dims: [1024])
      expect { described_class.generate(text: 'test', model: 'dims-model', dimensions: 3072, routing_seed: seed) }
        .to raise_error(Legion::LLM::Errors::RoutingRejected) { |e| expect(e.rejection.kind).to eq(:context_rejected) }
    end

    it 'returns the provider vector as-is when no dimension is requested (no truncate/pad)' do
      publish_embed(model: 'raw-model', dims: [768]) do |_op, _a, kwargs, _b|
        vecs = kwargs[:text].is_a?(Array) ? kwargs[:text].map { Array.new(768, 0.2) } : [Array.new(768, 0.2)]
        { result: vecs, usage: Legion::LLM::Usage.new(input_tokens: 4) }
      end
      result = described_class.generate(text: 'test', model: 'raw-model', routing_seed: seed)
      expect(result[:vector].size).to eq(768)
      expect(result[:dimensions]).to eq(768)
    end
  end

  describe '.generate token extraction' do
    it 'extracts tokens from a Usage object' do
      publish_embed(input_tokens: 42)
      result = described_class.generate(text: 'test', model: 'text-embedding-3-small', routing_seed: seed)
      expect(result[:tokens]).to eq(42)
    end

    it 'extracts tokens from a Hash usage' do
      publish_embed(model: 'hash-usage') do |_op, _a, kwargs, _b|
        vecs = kwargs[:text].is_a?(Array) ? kwargs[:text].map { Array.new(1024, 0.1) } : [Array.new(1024, 0.1)]
        { result: vecs, usage: { input_tokens: 7 } }
      end
      result = described_class.generate(text: 'test', model: 'hash-usage', routing_seed: seed)
      expect(result[:tokens]).to eq(7)
    end

    it 'defaults to 0 when no usage is present' do
      publish_embed(model: 'no-usage') do |_op, _a, kwargs, _b|
        vecs = kwargs[:text].is_a?(Array) ? kwargs[:text].map { Array.new(1024, 0.1) } : [Array.new(1024, 0.1)]
        { result: vecs, usage: nil }
      end
      result = described_class.generate(text: 'test', model: 'no-usage', routing_seed: seed)
      expect(result[:tokens]).to eq(0)
    end
  end

  describe '.generate text coercion (before prefix/chunking)' do
    it 'passes plain strings through unchanged' do
      publish_embed(model: 'coerce')
      described_class.generate(text: 'hello world', model: 'coerce', routing_seed: seed)
      expect(@dispatched.last[:text]).to eq('hello world')
    end

    it 'flattens structured text blocks from an array' do
      publish_embed(model: 'coerce')
      described_class.generate(text: [{ type: 'text', text: 'what tools are available to you?' }],
                               model: 'coerce', routing_seed: seed)
      expect(@dispatched.last[:text]).to eq('what tools are available to you?')
    end

    it 'extracts text from a Hash input' do
      publish_embed(model: 'coerce')
      described_class.generate(text: { text: 'from hash' }, model: 'coerce', routing_seed: seed)
      expect(@dispatched.last[:text]).to eq('from hash')
    end
  end

  describe '.generate returns a well-formed vector hash' do
    it 'unwraps a single flat vector from providers that do not nest' do
      publish_embed(model: 'flat') do |_op, _a, _kwargs, _b|
        { result: Array.new(1024, 0.1), usage: Legion::LLM::Usage.new(input_tokens: 5) }
      end
      result = described_class.generate(text: 'test', model: 'flat', routing_seed: seed)
      expect(result[:vector].size).to eq(1024)
      expect(result[:dimensions]).to eq(1024)
    end
  end

  describe '.generate chunking (offering context contract, §21.1)' do
    it 'chunks oversized input, dispatches all chunks to the one lane, and aggregates' do
      captured = nil
      publish_embed(model: 'text-embedding-3-small', context: 200_000) do |_op, _a, kwargs, _b|
        captured = kwargs[:text]
        vectors = kwargs[:text].each_index.map { |i| Array.new(1024, (i + 1).to_f) }
        { result: vectors, usage: Legion::LLM::Usage.new(input_tokens: 30) }
      end
      # budget = min(200_000, 512) tokens * 4 chars = 2048 chars/chunk; 8192 / 2048 = 4 chunks.
      result = described_class.generate(text: 'a' * 8192, model: 'text-embedding-3-small', routing_seed: seed)
      expect(captured).to be_an(Array)
      expect(captured.size).to eq(4)
      expect(result[:chunks]).to eq(4)
      # equal-length chunks -> uniform weights -> mean of [1,2,3,4] = 2.5
      expect(result[:vector].first).to eq(2.5)
      expect(result[:tokens]).to eq(30)
    end
  end

  describe '.generate_batch (N -> N, ordering preserved)' do
    it 'returns one vector per input in order' do
      publish_embed(model: 'batch')
      results = described_class.generate_batch(texts: %w[hello world], model: 'batch', routing_seed: seed)
      expect(results.size).to eq(2)
      expect(results.first[:vector].size).to eq(1024)
      expect(results.map { |r| r[:index] }).to eq([0, 1])
    end

    it 'chunks an oversized batch entry and reassembles per-item vectors' do
      publish_embed(model: 'batch-chunk', context: 200_000) do |_op, _a, kwargs, _b|
        vectors = kwargs[:text].each_index.map { |i| Array.new(1024, (i + 1).to_f) }
        { result: vectors, usage: Legion::LLM::Usage.new(input_tokens: 30) }
      end
      results = described_class.generate_batch(texts: ['short', 'b' * 8192], model: 'batch-chunk', routing_seed: seed)
      expect(results.size).to eq(2)
      expect(results.first[:chunks]).to eq(1)
      expect(results.last[:chunks]).to eq(4)
      expect(results.map { |r| r[:index] }).to eq([0, 1])
    end
  end

  describe 'lifecycle guard (precondition, not a routing outcome)' do
    it '.generate returns a not-started hash without selecting when LLM is not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      expect(Legion::LLM::Router).not_to receive(:next_lane)
      result = described_class.generate(text: 'test', model: 'x', routing_seed: seed)
      expect(result[:error]).to eq('LLM not started')
      expect(result[:vector]).to be_nil
    end

    it '.generate_batch returns one not-started hash per input' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      results = described_class.generate_batch(texts: %w[a b c], model: 'x', routing_seed: seed)
      expect(results.size).to eq(3)
      expect(results).to all(include(error: 'LLM not started', vector: nil))
    end
  end
end
