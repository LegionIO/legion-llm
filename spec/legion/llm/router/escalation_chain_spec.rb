# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/resolution'
require 'legion/llm/router/escalation_chain'

RSpec.describe Legion::LLM::Router::EscalationChain do
  let(:res_local) { Legion::LLM::Router::Resolution.new(tier: :local, provider: :ollama, model: 'llama3', rule: 'local-rule') }
  let(:res_fleet) { Legion::LLM::Router::Resolution.new(tier: :fleet, provider: :ollama, model: 'llama4:70b', rule: 'fleet-rule') }
  let(:res_cloud) { Legion::LLM::Router::Resolution.new(tier: :cloud, provider: :bedrock, model: 'claude-sonnet-4-6', rule: 'cloud-rule') }

  describe '#primary' do
    it 'returns the first resolution' do
      chain = described_class.new(resolutions: [res_local, res_fleet, res_cloud])
      expect(chain.primary).to eq(res_local)
    end
  end

  describe '#each' do
    it 'yields resolutions up to max_attempts' do
      chain = described_class.new(resolutions: [res_local, res_fleet, res_cloud], max_attempts: 2)
      yielded = chain.map { |r| r }
      expect(yielded).to eq([res_local, res_fleet])
    end

    it 'returns an enumerator when no block given' do
      chain = described_class.new(resolutions: [res_local, res_fleet])
      expect(chain.each).to be_a(Enumerator)
    end
  end

  describe '#size' do
    it 'returns total resolutions count' do
      chain = described_class.new(resolutions: [res_local, res_fleet, res_cloud])
      expect(chain.size).to eq(3)
    end
  end

  describe '#to_a' do
    it 'returns a copy of the resolutions array' do
      chain = described_class.new(resolutions: [res_local])
      arr = chain.to_a
      arr << res_fleet
      expect(chain.size).to eq(1)
    end
  end

  describe '#empty?' do
    it 'returns true when no resolutions' do
      chain = described_class.new(resolutions: [])
      expect(chain).to be_empty
    end

    it 'returns false when resolutions exist' do
      chain = described_class.new(resolutions: [res_local])
      expect(chain).not_to be_empty
    end
  end

  describe 'max_attempts default' do
    it 'defaults to 3' do
      chain = described_class.new(resolutions: [res_local, res_fleet, res_cloud])
      expect(chain.max_attempts).to eq(3)
    end
  end
end
