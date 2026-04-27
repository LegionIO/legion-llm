# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/call/bedrock_embeddings'

RSpec.describe 'Bedrock embedding patch' do
  # Instance of the patched class. We don't make real HTTP calls — the patched
  # methods we exercise here are pure payload builders / URL helpers, so no
  # RubyLLM::Configuration is needed.
  let(:bedrock) do
    klass = RubyLLM::Providers::Bedrock
    klass.allocate.tap do |inst|
      inst.instance_variable_set(:@model, nil)
    end
  end

  describe 'probe contract' do
    it 'exposes render_embedding_payload as an instance method (probe passes)' do
      expect(RubyLLM::Providers::Bedrock.instance_method(:render_embedding_payload)).to be_a(UnboundMethod)
    end

    it 'exposes embedding_url and parse_embedding_response' do
      expect(RubyLLM::Providers::Bedrock.instance_method(:embedding_url)).to be_a(UnboundMethod)
      expect(RubyLLM::Providers::Bedrock.instance_method(:parse_embedding_response)).to be_a(UnboundMethod)
    end
  end

  describe '#embedding_url' do
    it 'returns /model/<id>/invoke for valid model ids' do
      expect(bedrock.embedding_url(model: 'amazon.titan-embed-text-v2:0'))
        .to eq('/model/amazon.titan-embed-text-v2:0/invoke')
    end

    it 'rejects model ids with unsafe characters' do
      expect { bedrock.embedding_url(model: 'foo/../bar') }
        .to raise_error(RubyLLM::Error, /Invalid Bedrock model id/)
    end

    it 'rejects empty model ids' do
      expect { bedrock.embedding_url(model: '') }
        .to raise_error(RubyLLM::Error)
    end
  end

  describe '#render_embedding_payload — Titan v2' do
    let(:model) { 'amazon.titan-embed-text-v2:0' }

    it 'builds a single-text payload with normalize=true' do
      payload = bedrock.send(:render_embedding_payload, 'hello world', model: model, dimensions: nil)
      expect(payload).to include(inputText: 'hello world', normalize: true)
      expect(payload).not_to have_key(:dimensions)
    end

    it 'includes dimensions when valid (1024)' do
      payload = bedrock.send(:render_embedding_payload, 'hi', model: model, dimensions: 1024)
      expect(payload[:dimensions]).to eq(1024)
    end

    it 'accepts 256 and 512 dimensions' do
      expect(bedrock.send(:render_embedding_payload, 'hi', model: model, dimensions: 256)[:dimensions]).to eq(256)
      expect(bedrock.send(:render_embedding_payload, 'hi', model: model, dimensions: 512)[:dimensions]).to eq(512)
    end

    it 'raises on invalid dimensions (not silent drop)' do
      expect { bedrock.send(:render_embedding_payload, 'hi', model: model, dimensions: 768) }
        .to raise_error(RubyLLM::Error, /dimensions must be one of/)
    end

    it 'raises on Array input (Titan is single-text)' do
      expect { bedrock.send(:render_embedding_payload, %w[a b], model: model, dimensions: nil) }
        .to raise_error(RubyLLM::Error, /single string per invocation/)
    end

    it 'raises when input exceeds TITAN_MAX_INPUT_BYTES' do
      huge = 'x' * 50_000
      expect { bedrock.send(:render_embedding_payload, huge, model: model, dimensions: nil) }
        .to raise_error(RubyLLM::Error, /input too large/)
    end
  end

  describe '#render_embedding_payload — Titan v1' do
    let(:model) { 'amazon.titan-embed-text-v1' }

    it 'builds a bare inputText payload (no dimensions support)' do
      payload = bedrock.send(:render_embedding_payload, 'hello', model: model, dimensions: 1024)
      expect(payload).to eq(inputText: 'hello')
    end

    it 'raises on Array input (parity with v2)' do
      expect { bedrock.send(:render_embedding_payload, %w[a b], model: model, dimensions: nil) }
        .to raise_error(RubyLLM::Error, /single string per invocation/)
    end
  end

  describe '#render_embedding_payload — Cohere Embed' do
    let(:model) { 'cohere.embed-english-v3' }

    it 'builds a texts payload with search_document input_type' do
      payload = bedrock.send(:render_embedding_payload, 'hello', model: model, dimensions: nil)
      expect(payload).to eq(texts: ['hello'], input_type: 'search_document')
    end

    it 'accepts batch input' do
      payload = bedrock.send(:render_embedding_payload, %w[a b c], model: model, dimensions: nil)
      expect(payload[:texts]).to eq(%w[a b c])
    end

    it 'rejects batches over COHERE_MAX_TEXTS (96)' do
      too_many = Array.new(97) { |i| "text #{i}" }
      expect { bedrock.send(:render_embedding_payload, too_many, model: model, dimensions: nil) }
        .to raise_error(RubyLLM::Error, /exceeds max 96/)
    end
  end

  describe '#render_embedding_payload — unsupported model' do
    it 'raises a helpful error listing supported prefixes' do
      expect { bedrock.send(:render_embedding_payload, 'x', model: 'something.else-v1', dimensions: nil) }
        .to raise_error(RubyLLM::Error, /not supported for embeddings/)
    end
  end

  describe '#parse_embedding_response' do
    let(:titan_response) do
      instance_double(
        Faraday::Response,
        body: { 'embedding' => [0.1, 0.2, 0.3], 'inputTextTokenCount' => 5 }
      )
    end

    let(:cohere_response) do
      instance_double(
        Faraday::Response,
        body: { 'embeddings' => [[0.1, 0.2], [0.3, 0.4]] }
      )
    end

    it 'parses Titan single-text responses' do
      emb = bedrock.send(:parse_embedding_response, titan_response, model: 'amazon.titan-embed-text-v2:0', text: 'hi')
      expect(emb).to be_a(RubyLLM::Embedding)
      expect(emb.vectors).to eq([0.1, 0.2, 0.3])
      expect(emb.input_tokens).to eq(5)
    end

    it 'parses Cohere batch responses' do
      emb = bedrock.send(:parse_embedding_response, cohere_response, model: 'cohere.embed-english-v3', text: %w[a b])
      expect(emb.vectors).to eq([[0.1, 0.2], [0.3, 0.4]])
    end

    it 'raises on empty vector response (instead of returning an empty Embedding)' do
      empty_response = instance_double(Faraday::Response, body: { 'inputTextTokenCount' => 0 })
      expect do
        bedrock.send(:parse_embedding_response, empty_response, model: 'amazon.titan-embed-text-v2:0', text: 'hi')
      end.to raise_error(RubyLLM::Error, /Empty embedding response/)
    end
  end
end
