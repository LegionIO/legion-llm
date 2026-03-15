# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'

RSpec.describe 'Legion::LLM.chat router integration' do
  let(:sample_rules) do
    [
      {
        name:            'basic-local',
        when:            { capability: 'basic' },
        then:            { tier: 'local', provider: 'ollama', model: 'qwen3:7b' },
        priority:        80,
        cost_multiplier: 0.2
      },
      {
        name:            'cloud-override',
        when:            { capability: 'reasoning' },
        then:            { tier: 'cloud', provider: 'bedrock', model: 'claude-sonnet-4-6' },
        priority:        50,
        cost_multiplier: 2.0
      }
    ]
  end

  before do
    Legion::LLM::Router.reset!
    allow(Legion::LLM::Router).to receive(:tier_available?).and_return(true)

    Legion::Settings[:llm][:routing] = {
      enabled: true,
      rules:   sample_rules
    }
  end

  describe 'intent-based routing' do
    it 'routes to resolved provider/model when intent matches a rule' do
      expect(RubyLLM).to receive(:chat).with(model: 'qwen3:7b', provider: :ollama)
      Legion::LLM.chat(intent: { capability: :basic })
    end
  end

  describe 'pass-through when no routing params given' do
    it 'calls RubyLLM.chat with explicit model and provider unchanged' do
      expect(RubyLLM).to receive(:chat).with(model: 'gpt-4o', provider: :openai)
      Legion::LLM.chat(model: 'gpt-4o', provider: :openai)
    end
  end

  describe 'tier override' do
    it 'forces tier and maps to cloud provider when tier: :cloud is given with explicit model/provider' do
      # tier: :cloud triggers explicit_resolution, provider/model come from the call
      expect(RubyLLM).to receive(:chat).with(model: 'gpt-4o', provider: :openai)
      Legion::LLM.chat(tier: :cloud, model: 'gpt-4o', provider: :openai)
    end
  end

  describe 'routing disabled' do
    before do
      Legion::Settings[:llm][:routing] = { enabled: false, rules: sample_rules }
    end

    it 'ignores intent and falls through to defaults without routing the call' do
      # With routing disabled, intent is ignored; RubyLLM.chat receives no model/provider (defaults nil)
      chat_double = double('chat')
      allow(RubyLLM).to receive(:chat).and_return(chat_double)
      Legion::LLM.chat(intent: { capability: :basic })
      # Verify Router was NOT used to override anything (call went through with no model/provider)
      expect(RubyLLM).to have_received(:chat).with(no_args)
    end
  end

  describe 'when Router.resolve returns nil' do
    it 'falls through to defaults when no rule matches intent' do
      # Use an intent that matches no rules
      result_double = double('chat')
      allow(RubyLLM).to receive(:chat).and_return(result_double)
      expect { Legion::LLM.chat(intent: { capability: :unknown_capability }) }.not_to raise_error
    end
  end
end
