# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Router::GatewayInterceptor do
  let(:resolution) do
    Legion::LLM::Router::Resolution.new(tier: :cloud, provider: :bedrock, model: 'claude-sonnet-4-6', rule: 'test')
  end

  before do
    Legion::Settings[:llm] = Legion::LLM::Settings.default.merge(
      gateway: { enabled: true, endpoint: 'https://gateway.example.com/v1', model_policy: {} }
    )
  end

  describe '.intercept' do
    it 'rewrites cloud resolution to gateway provider' do
      result = described_class.intercept(resolution)
      expect(result.provider).to eq(:gateway)
      expect(result.model).to eq('claude-sonnet-4-6')
      expect(result.metadata[:original_provider]).to eq(:bedrock)
    end

    it 'rewrites frontier resolution to gateway provider' do
      frontier = Legion::LLM::Router::Resolution.new(tier: :frontier, provider: :anthropic, model: 'claude-sonnet-4-6')
      result = described_class.intercept(frontier)
      expect(result.provider).to eq(:gateway)
      expect(result.tier).to eq(:frontier)
      expect(result.metadata[:original_provider]).to eq(:anthropic)
    end

    it 'passes through non-cloud resolutions' do
      local = Legion::LLM::Router::Resolution.new(tier: :local, provider: :ollama, model: 'llama3')
      result = described_class.intercept(local)
      expect(result.provider).to eq(:ollama)
    end

    it 'passes through when gateway disabled' do
      Legion::Settings[:llm] = Legion::LLM::Settings.default.merge(
        gateway: { enabled: false }
      )
      result = described_class.intercept(resolution)
      expect(result).to eq(resolution)
    end

    it 'returns nil when model blocked by policy' do
      Legion::Settings[:llm] = Legion::LLM::Settings.default.merge(
        gateway: { enabled: true, endpoint: 'https://gw.example.com', model_policy: { high: ['gpt-*'] } }
      )
      result = described_class.intercept(resolution, context: { risk_tier: :high })
      expect(result).to be_nil
    end
  end

  describe '.model_allowed?' do
    it 'allows when no policy for risk tier' do
      expect(described_class.model_allowed?('claude-sonnet-4-6', :low)).to be true
    end

    it 'allows when model matches fnmatch pattern' do
      Legion::Settings[:llm] = Legion::LLM::Settings.default.merge(
        gateway: { model_policy: { high: ['claude-*'] } }
      )
      expect(described_class.model_allowed?('claude-sonnet-4-6', :high)).to be true
    end

    it 'blocks when model does not match any pattern' do
      Legion::Settings[:llm] = Legion::LLM::Settings.default.merge(
        gateway: { model_policy: { critical: ['claude-sonnet-4-6'] } }
      )
      expect(described_class.model_allowed?('gpt-4o', :critical)).to be false
    end
  end

  describe '.gateway_headers' do
    it 'builds headers from context' do
      headers = described_class.gateway_headers(worker_id: 'w1', tenant_id: 't1', risk_tier: :high)
      expect(headers['X-Agent-Id']).to eq('w1')
      expect(headers['X-Tenant-Id']).to eq('t1')
      expect(headers['X-Risk-Tier']).to eq('high')
    end

    it 'omits nil values' do
      headers = described_class.gateway_headers(worker_id: 'w1')
      expect(headers).not_to have_key('X-Tenant-Id')
    end
  end
end
