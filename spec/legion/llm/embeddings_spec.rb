# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/call/embeddings'

# M4: SSOT :embed routing (Call::Embeddings → Router.next_lane) is the SOLE
# selection authority for embeddings. Discovery no longer selects a
# provider/instance/model (the settings-pin → tier-rank → default_model chain
# and its @embedding_* state are gone); can_embed? is a live capability fact
# against the same Inventory lane store the router reads.
RSpec.describe 'Legion::LLM embedding capability', :ssot_v3 do
  before do
    Legion::Extensions::Llm::Inventory::Registry.reset!
  end

  after do
    Legion::Extensions::Llm::Inventory::Registry.reset!
  end

  def publish_embed_lane(model, provider: :ollama, instance: :gpu_box, tier: :local, capabilities: %i[embedding])
    write_test_lane(provider: provider, instance: instance, model: model, tier: tier,
                    type: capabilities.include?(:embedding) ? :embedding : :inference,
                    capabilities: capabilities)
  end

  describe '.can_embed?' do
    it 'is false when no embedding-type lane is published' do
      publish_embed_lane('gemma-4-31b-it', capabilities: %i[chat streaming])
      expect(Legion::LLM::Inventory::Discovery.can_embed?).to be false
      expect(Legion::LLM.can_embed?).to be false
    end

    it 'is true when an embedding-type lane is published (live registry fact)' do
      publish_embed_lane('mxbai-embed-large')
      expect(Legion::LLM::Inventory::Discovery.can_embed?).to be true
      expect(Legion::LLM.can_embed?).to be true
    end

    it 'tracks lane publication without boot-time detection state' do
      expect(Legion::LLM.can_embed?).to be false
      publish_embed_lane('mxbai-embed-large')
      expect(Legion::LLM.can_embed?).to be true
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
      { embedding: vectors, usage: { input_tokens: input_tokens } }
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
        { embedding: vecs, usage: { input_tokens: 4 } }
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
        { embedding: vecs, usage: { input_tokens: 7 } }
      end
      result = described_class.generate(text: 'test', model: 'hash-usage', routing_seed: seed)
      expect(result[:tokens]).to eq(7)
    end

    it 'defaults to 0 when no usage is present' do
      publish_embed(model: 'no-usage') do |_op, _a, kwargs, _b|
        vecs = kwargs[:text].is_a?(Array) ? kwargs[:text].map { Array.new(1024, 0.1) } : [Array.new(1024, 0.1)]
        { embedding: vecs, usage: nil }
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
        { embedding: Array.new(1024, 0.1), usage: { input_tokens: 5 } }
      end
      result = described_class.generate(text: 'test', model: 'flat', routing_seed: seed)
      expect(result[:vector].size).to eq(1024)
      expect(result[:dimensions]).to eq(1024)
    end

    # Legacy-shape preservation: a callable that returns a BARE numeric array
    # (no Hash wrapper, pre-SSOT shape) must keep working.
    it 'still accepts a callable that returns a raw numeric array' do
      publish_embed(model: 'raw-array') do |_op, _a, kwargs, _b|
        texts = kwargs[:text]
        texts.is_a?(Array) ? texts.map { Array.new(1024, 0.3) } : Array.new(1024, 0.3)
      end
      result = described_class.generate(text: 'test', model: 'raw-array', routing_seed: seed)
      expect(result[:vector].size).to eq(1024)
      expect(result[:vector].first).to eq(0.3)
      expect(result[:tokens]).to eq(0)
    end
  end

  # Production SSOT v3 callable contract: the lex-llm-* parse_embedding_response
  # 0.8.0 embed artifact (05 S3 / O07): the documented Hash
  # { text:, model:, embedding: Array<Float>, usage: Canonical::Usage } — a flat
  # numeric vector for a single input, an Array of them for a batch. The embed
  # consumer unwraps it at the boundary (provider_vectors).
  describe '.generate 0.8.0 documented embed artifact' do
    it 'unwraps the artifact: vectors returned, input_tokens extracted' do
      publish_embed(model: 'native-embed') do |_op, _a, kwargs, _b|
        texts = kwargs[:text]
        vectors = texts.is_a?(Array) ? texts.map { Array.new(1024, 0.1) } : Array.new(1024, 0.1)
        { text: texts, model: 'native-embed', embedding: vectors, usage: { input_tokens: 37 } }
      end
      result = described_class.generate(text: 'test', model: 'native-embed', routing_seed: seed)
      expect(result[:vector].size).to eq(1024)
      expect(result[:vector].first).to eq(0.1)
      expect(result[:tokens]).to eq(37)
    end

    it 'unwraps an artifact carrying one vector per batch entry' do
      publish_embed(model: 'native-batch') do |_op, _a, kwargs, _b|
        vectors = kwargs[:text].each_index.map { |i| Array.new(1024, (i + 1).to_f) }
        { text: kwargs[:text], model: 'native-batch', embedding: vectors, usage: { input_tokens: 30 } }
      end
      results = described_class.generate_batch(texts: %w[hello world], model: 'native-batch', routing_seed: seed)
      expect(results.size).to eq(2)
      expect(results.map { |r| r[:index] }).to eq([0, 1])
      expect(results.first[:vector].first).to eq(1.0)
      expect(results.last[:vector].first).to eq(2.0)
    end
  end

  describe '.generate chunking (offering context contract, §21.1)' do
    it 'chunks oversized input, dispatches all chunks to the one lane, and aggregates' do
      captured = nil
      publish_embed(model: 'text-embedding-3-small', context: 200_000) do |_op, _a, kwargs, _b|
        captured = kwargs[:text]
        vectors = kwargs[:text].each_index.map { |i| Array.new(1024, (i + 1).to_f) }
        { embedding: vectors, usage: { input_tokens: 30 } }
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
        { embedding: vectors, usage: { input_tokens: 30 } }
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
