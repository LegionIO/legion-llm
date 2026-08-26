# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM do
  describe '.settings' do
    it 'returns default settings hash' do
      settings = described_class.settings
      expect(settings).to be_a(Hash)
      expect(settings[:enabled]).to be true
      expect(settings[:connected]).to be false
    end

    it 'provider defaults now live in Settings[:extensions][:llm] (populated by lex-llm-* extensions)' do
      ext = Legion::Settings[:extensions][:llm]
      expect(ext).to be_a(Hash)
    end
  end

  describe '.start and .shutdown' do
    before do
      Legion::Settings[:extensions][:llm][:ollama] = { enabled: true, base_url: 'http://localhost:11434' }
      stub_request(:get, 'http://localhost:11434/api/tags')
        .to_return(status: 200, body: { 'models' => [] }.to_json)
      stub_request(:get, 'http://localhost:8000/v1/models')
        .to_return(status: 200, body: { 'data' => [] }.to_json)
      stub_request(:get, 'http://localhost:8000/health')
        .to_return(status: 200, body: '{}')
    end

    after do
      described_class.shutdown if described_class.started?
    end

    it 'marks connected on start' do
      described_class.start
      expect(described_class.started?).to be true
      expect(Legion::Settings[:llm][:connected]).to be true
    end

    it 'marks disconnected on shutdown' do
      described_class.start
      described_class.shutdown
      expect(described_class.started?).to be false
      expect(Legion::Settings[:llm][:connected]).to be false
    end

    # M4: can_embed? is a live capability fact from the inventory registry
    # (no boot-time detection state to reset on shutdown) — the second
    # selection domain and its embedding_provider/model/instance projections
    # are gone.
    it 'answers can_embed? from the live inventory registry, not cached state' do
      Legion::Extensions::Llm::Inventory::Registry.reset!
      expect(Legion::LLM.can_embed?).to be false
      write_test_lane(provider: :ollama, instance: :gpu_box, model: 'mxbai-embed-large', type: :embedding)
      expect(Legion::LLM.can_embed?).to be true
    ensure
      Legion::Extensions::Llm::Inventory::Registry.reset!
    end

    it 'gracefully shuts down the async thread pool on shutdown' do
      described_class.start
      described_class.shutdown
      expect(Legion::LLM::Inference::Executor::ASYNC_THREAD_POOL.shutdown?).to be true
    end

    it 'registers routes with Legion::API when available on start' do
      fake_api = Module.new do
        def self.register_library_routes(name, mod); end
      end
      stub_const('Legion::API', fake_api)
      expect(Legion::API).to receive(:register_library_routes).with('llm', Legion::LLM::Routes)
      described_class.start
    end

    it 'skips route registration when Legion::API is not defined' do
      hide_const('Legion::API') if defined?(Legion::API)
      expect { described_class.start }.not_to raise_error
    end
  end

  describe 'auto_configure_defaults' do
    before do
      stub_request(:get, 'http://localhost:11434/api/tags')
        .to_return(status: 200, body: { 'models' => [] }.to_json)
      stub_request(:get, 'http://localhost:8000/v1/models')
        .to_return(status: 200, body: { 'data' => [] }.to_json)
      stub_request(:get, 'http://localhost:8000/health')
        .to_return(status: 200, body: '{}')
      # Clear any env-var-seeded defaults so auto_configure_defaults actually runs
      Legion::Settings[:llm][:default_model]    = nil
      Legion::Settings[:llm][:default_provider] = nil
    end

    it 'picks bedrock when bedrock is the first enabled provider' do
      Legion::Settings[:extensions][:llm] = {
        bedrock: { enabled: true, default_model: 'us.anthropic.claude-sonnet-4-6-v1', region: 'us-east-2' }
      }
      described_class.start
      expect(Legion::Settings[:llm][:default_provider]).to eq(:bedrock)
    end

    it 'picks anthropic when only anthropic is enabled' do
      Legion::Settings[:extensions][:llm] = {
        bedrock:   { enabled: false },
        anthropic: { enabled: true, default_model: 'claude-sonnet-4-6' }
      }
      described_class.start
      expect(Legion::Settings[:llm][:default_provider]).to eq(:anthropic)
    end

    it 'respects explicit default_model setting' do
      Legion::Settings[:llm][:default_model] = 'custom-model'
      Legion::Settings[:llm][:default_provider] = :openai
      described_class.start
      expect(Legion::Settings[:llm][:default_model]).to eq('custom-model')
    end
  end

  describe Legion::LLM::Settings do
    describe '.default' do
      it 'returns a hash with expected keys' do
        defaults = described_class.default
        expect(defaults).to include(:enabled, :connected, :default_model, :default_provider)
      end

      it 'includes an empty providers hash (provider configs come from lex-llm-* extensions at runtime)' do
        expect(described_class.default[:providers]).to eq({})
      end
    end
  end
end
