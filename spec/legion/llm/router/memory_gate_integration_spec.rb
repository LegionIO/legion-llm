# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'
require 'legion/llm/discovery/memory_gate'
require 'legion/llm/discovery/system'

RSpec.describe 'Router memory gate integration' do
  let(:local_rule) do
    {
      name:     'local-ollama',
      when:     { capability: 'basic' },
      then:     { tier: 'local', provider: 'ollama', model: 'llama3:latest' },
      priority: 80
    }
  end

  let(:fleet_rule) do
    {
      name:     'fleet-vllm',
      when:     { capability: 'basic' },
      then:     { tier: 'fleet', provider: 'vllm', model: 'qwen3.6-27b' },
      priority: 60
    }
  end

  def configure_routing(rules:)
    Legion::Settings.set_prop(:llm, Legion::Settings[:llm].merge(
                                      routing: {
                                        enabled:        true,
                                        rules:          rules,
                                        default_intent: { privacy: 'normal', capability: 'basic' }
                                      }
                                    ))
    Legion::LLM::Router.populate_auto_rules({})
  end

  before do
    Legion::LLM::Router.reset!
    allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
    allow(Legion::LLM::Discovery).to receive(:model_available?).and_return(true)
    allow(Legion::LLM::Discovery).to receive(:model_size).and_return(nil)
    allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(65_536)
  end

  after { Legion::LLM::Router.reset! }

  describe 'excluded_by_memory? for fleet-tier rules' do
    it 'does not reject fleet-tier vllm rules' do
      configure_routing(rules: [fleet_rule])
      # vllm is :fleet tier, memory gate only checks :local
      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.provider).to eq(:vllm)
    end
  end

  describe 'excluded_by_memory? for local-tier rules' do
    it 'keeps local rules when memory gate allows' do
      allow(Legion::LLM::Discovery::MemoryGate).to receive(:allow?).and_return(true)
      configure_routing(rules: [local_rule])

      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.provider).to eq(:ollama)
    end

    it 'rejects local rules when memory gate denies and falls back to arbitrage' do
      allow(Legion::LLM::Discovery::MemoryGate).to receive(:allow?).and_return(false)
      configure_routing(rules: [local_rule])

      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      # New behavior: when all rules are rejected, falls back to arbitrage
      # rather than returning nil
      expect(result).not_to be_nil
    end

    it 'falls through to fleet rule when local is rejected by memory' do
      allow(Legion::LLM::Discovery::MemoryGate).to receive(:allow?).and_return(false)

      configure_routing(rules: [local_rule, fleet_rule])

      result = Legion::LLM::Router.resolve(intent: { capability: 'basic' })
      expect(result).not_to be_nil
      expect(result.provider).to eq(:vllm)
      expect(result.tier).to eq(:fleet)
    end
  end
end
