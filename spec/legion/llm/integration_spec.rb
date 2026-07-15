# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'
require 'legion/llm/inventory/discovery/system'

RSpec.describe 'Legion::LLM.chat router integration' do
  let(:sample_rules) do
    [
      {
        name:            'low-effort-local',
        when:            { effort: 'low' },
        then:            { tier: 'local', provider: 'ollama', model: 'qwen3:7b', effort: 'low' },
        priority:        80,
        cost_multiplier: 0.2
      },
      {
        name:            'cloud-reasoning',
        when:            { effort: 'reasoning' },
        then:            { tier: 'cloud', provider: 'bedrock', model: 'claude-sonnet-4-6', effort: 'reasoning' },
        priority:        50,
        cost_multiplier: 2.0
      }
    ]
  end

  before do
    Legion::LLM::Router.reset!
    allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)
    allow(Legion::LLM::Discovery).to receive(:model_available?).and_return(true)
    allow(Legion::LLM::Discovery).to receive(:model_size).and_return(nil)
    allow(Legion::LLM::Discovery::System).to receive(:available_memory_mb).and_return(65_536)

    Legion::Settings[:llm][:routing][:enabled] = true
    Legion::Settings[:llm][:routing][:rules] = sample_rules
    Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = false
    Legion::Settings[:llm][:default_provider] = :ollama
    Legion::Settings[:llm][:default_model] = 'qwen3:7b'
  end

  describe 'intent-based routing' do
    it 'routes to resolved provider/model when intent matches a rule' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call)
        .with(hash_including(model: 'qwen3:7b', provider: :ollama))
        .and_return(native_dispatch_result(content: 'pipeline response'))
      Legion::LLM.chat(intent: { effort: :low }, message: 'hello')
    end
  end

  describe 'pass-through when no routing params given' do
    it 'calls native dispatch with explicit model and provider unchanged' do
      expect(Legion::LLM::Call::Dispatch).to receive(:call)
        .with(hash_including(model: 'gpt-4o', provider: :openai))
        .and_return(native_dispatch_result(content: 'pipeline response'))
      Legion::LLM.chat(model: 'gpt-4o', provider: :openai, message: 'hello')
    end
  end

  describe 'tier override' do
    it 'forces tier and maps to cloud provider when tier: :cloud is given with explicit model/provider' do
      # tier: :cloud triggers explicit_resolution, provider/model come from the call
      expect(Legion::LLM::Call::Dispatch).to receive(:call)
        .with(hash_including(model: 'gpt-4o', provider: :openai))
        .and_return(native_dispatch_result(content: 'pipeline response'))
      Legion::LLM.chat(tier: :cloud, model: 'gpt-4o', provider: :openai, message: 'hello')
    end
  end

  describe 'routing disabled' do
    before do
      Legion::Settings[:llm][:routing][:enabled] = false
      Legion::Settings[:llm][:routing][:rules] = sample_rules
    end

    it 'ignores intent and falls through to defaults without routing the call' do
      # With routing disabled, intent is ignored and Router.resolve is never called
      allow(Legion::LLM::Call::Dispatch).to receive(:call).and_return(native_dispatch_result(content: 'pipeline response'))
      expect(Legion::LLM::Router).not_to receive(:resolve)
      Legion::LLM.chat(intent: { effort: :low }, message: 'hello')
    end
  end

  describe 'when Router.resolve returns nil' do
    it 'falls through to defaults when no rule matches intent' do
      # Use an intent that matches no rules
      allow(Legion::LLM::Call::Dispatch).to receive(:call).and_return(native_dispatch_result(content: 'pipeline response'))
      expect { Legion::LLM.chat(intent: { operation: :embed }, message: 'hello') }.not_to raise_error
    end
  end
end
