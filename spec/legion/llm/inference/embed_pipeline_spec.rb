# frozen_string_literal: true

require 'spec_helper'
require 'legion/cache'
require 'legion/llm/inference/embed_pipeline'
require 'tmpdir'

RSpec.describe Legion::LLM::Inference::EmbedPipeline, :ssot_v3 do
  let(:model) { 'mxbai-embed-large:latest' }
  let(:seed) { '9f' * 16 }
  let(:callable) do
    SsotV3SnapshotFactory::FactoryCallable.new(responder: lambda do |*_args|
      {
        embedding: [0.1, 0.2, 0.3],
        usage:     Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: 37)
      }
    end)
  end

  around do |example|
    Dir.mktmpdir('embedding_metering') do |directory|
      @spool_path = File.join(directory, 'events.jsonl')
      example.run
    end
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    Legion::Cache.setup
    Legion::Settings[:transport][:connected] = false
    Legion::Settings[:llm][:compliance][:encrypt_spool] = false
    Legion::Settings[:llm][:metering][:spool][:path] = @spool_path
    activate(
      provider_family: 'ollama', instance_id: 'primary', callable: callable,
      drafts: [offering_draft(model: model, tier: :direct, supported: %i[embed],
                              capabilities: { embedding: :supported },
                              embedding_dimensions: [3], context: 512)]
    )
  end

  it 'counts cached request tokens for savings accounting without another provider execution' do
    results = Array.new(2) do
      described_class.call(text: 'hello world', model: model, dimensions: 3, routing_seed: seed)
    end
    events = File.readlines(@spool_path).map { |line| Legion::JSON.load(line) }

    expect(results.map { |result| result[:cache_hit] }).to eq([false, true])
    expect(results.map { |result| result[:tokens] }).to eq([37, 37])
    expect(callable.inference_calls).to eq(1)
    expect(events.map { |event| event.slice(:request_type, :input_tokens, :output_tokens, :total_tokens, :cache_hit) }).to eq(
      [
        { request_type: 'embedding', input_tokens: 37, output_tokens: 0, total_tokens: 37, cache_hit: false },
        { request_type: 'embedding', input_tokens: 37, output_tokens: 0, total_tokens: 37, cache_hit: true }
      ]
    )
    expect(events.first).not_to have_key(:cost_usd)
    expect(events.last[:cost_usd]).to eq(0)
  end

  it 'does not emit successful request accounting when routing rejects the embedding' do
    Legion::Extensions::Llm::Inventory::Registry.reset!

    expect do
      described_class.call(text: 'hello world', model: model, dimensions: 3, routing_seed: seed)
    end.to raise_error(Legion::LLM::Errors::RoutingRejected)

    expect(callable.inference_calls).to eq(0)
    expect(File.exist?(@spool_path)).to be(false)
  end

  context 'when provider execution raises a programming error' do
    let(:provider_error) { TypeError.new('invalid embedding response') }
    let(:callable) do
      SsotV3SnapshotFactory::FactoryCallable.new(responder: ->(*_args) { raise provider_error })
    end

    it 'logs and propagates the error without emitting successful accounting' do
      expect(described_class).to receive(:handle_exception)
        .with(provider_error, level: :warn, operation: 'llm.embed_pipeline.call').and_call_original

      expect do
        described_class.call(text: 'hello world', model: model, dimensions: 3, routing_seed: seed)
      end.to raise_error(provider_error)

      expect(callable.inference_calls).to eq(1)
      expect(File.exist?(@spool_path)).to be(false)
    end
  end
end
