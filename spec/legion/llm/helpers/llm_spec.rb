# frozen_string_literal: true

require 'spec_helper'

# Stub the namespace that only exists in the full LegionIO framework
module Legion
  module Extensions
    module Helpers
    end
  end
end

require 'legion/llm/helpers/llm'

RSpec.describe Legion::LLM::Helper do
  let(:test_class) { Class.new { include Legion::LLM::Helper } }
  let(:instance) { test_class.new }

  let(:mock_chat) { instance_double('RubyLLM::Chat') }
  let(:mock_response) { double('response', content: 'ok') }

  before do
    allow(Legion::LLM).to receive(:chat).and_return(mock_chat)
    allow(mock_chat).to receive(:with_instructions).and_return(mock_chat)
    allow(mock_chat).to receive(:with_tools).and_return(mock_chat)
    allow(mock_chat).to receive(:ask).and_return(mock_response)
  end

  describe '#llm_default_model' do
    it 'returns the settings value' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :default_model).and_return('claude-sonnet-4-6')
      expect(instance.llm_default_model).to eq('claude-sonnet-4-6')
    end

    it 'returns nil when not configured' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :default_model).and_return(nil)
      expect(instance.llm_default_model).to be_nil
    end

    it 'can be overridden by a LEX' do
      custom_class = Class.new do
        include Legion::LLM::Helper

        def llm_default_model
          'llama3'
        end
      end
      expect(custom_class.new.llm_default_model).to eq('llama3')
    end
  end

  describe '#llm_default_provider' do
    it 'returns the settings value' do
      allow(Legion::Settings).to receive(:dig).with(:llm, :default_provider).and_return(:bedrock)
      expect(instance.llm_default_provider).to eq(:bedrock)
    end

    it 'can be overridden by a LEX' do
      custom_class = Class.new do
        include Legion::LLM::Helper

        def llm_default_provider
          :ollama
        end
      end
      expect(custom_class.new.llm_default_provider).to eq(:ollama)
    end
  end

  describe '#llm_default_intent' do
    it 'returns the settings value' do
      intent = { privacy: 'normal', capability: 'moderate', cost: 'normal' }
      allow(Legion::Settings).to receive(:dig).with(:llm, :routing, :default_intent).and_return(intent)
      expect(instance.llm_default_intent).to eq(intent)
    end

    it 'can be overridden by a LEX' do
      custom_class = Class.new do
        include Legion::LLM::Helper

        def llm_default_intent
          { privacy: :strict, capability: :basic }
        end
      end
      expect(custom_class.new.llm_default_intent).to eq({ privacy: :strict, capability: :basic })
    end
  end

  describe '#llm_chat' do
    it 'compresses instructions when compress level is provided' do
      instance.llm_chat('hello', instructions: 'The very important system prompt', compress: 2)
      expect(mock_chat).to have_received(:with_instructions).with('important system prompt')
    end

    it 'compresses message when compress level is provided' do
      instance.llm_chat('The very important question', compress: 1)
      expect(mock_chat).to have_received(:ask).with('important question')
    end

    it 'does not compress when compress is 0' do
      instance.llm_chat('The very important question', compress: 0)
      expect(mock_chat).to have_received(:ask).with('The very important question')
    end

    it 'does not compress by default' do
      instance.llm_chat('The very important question')
      expect(mock_chat).to have_received(:ask).with('The very important question')
    end

    it 'applies layered model default when model is not provided' do
      allow(instance).to receive(:llm_default_model).and_return('llama3')
      allow(instance).to receive(:llm_default_provider).and_return(:ollama)
      allow(instance).to receive(:llm_default_intent).and_return(nil)

      instance.llm_chat('hello')
      expect(Legion::LLM).to have_received(:chat).with(
        hash_including(model: 'llama3', provider: :ollama, escalate: false)
      )
    end

    it 'prefers explicit model over layered default' do
      allow(instance).to receive(:llm_default_model).and_return('llama3')

      instance.llm_chat('hello', model: 'gpt-4o')
      expect(Legion::LLM).to have_received(:chat).with(
        hash_including(model: 'gpt-4o')
      )
    end
  end

  describe 'escalation passthrough' do
    it 'passes escalation kwargs to Legion::LLM.chat and returns response' do
      response = double('Response', content: 'escalated result')
      expect(Legion::LLM).to receive(:chat).with(
        hash_including(escalate: true, max_escalations: 5, message: 'test prompt')
      ).and_return(response)

      result = instance.llm_chat('test prompt', escalate: true, max_escalations: 5)
      expect(result).to eq(response)
    end

    it 'does not pass message: when escalate is not set' do
      mock_chat2 = double('RubyLLM::Chat')
      expect(Legion::LLM).to receive(:chat).with(
        hash_including(escalate: false)
      ).and_return(mock_chat2)
      expect(mock_chat2).not_to receive(:with_instructions)
      expect(mock_chat2).not_to receive(:with_tools)
      allow(mock_chat2).to receive(:ask).with('test').and_return(double('Response'))

      instance.llm_chat('test')
    end
  end

  describe '#llm_embed' do
    it 'forwards all keyword arguments to LLM.embed' do
      expect(Legion::LLM).to receive(:embed).with('test text', provider: :ollama, dimensions: 1024)
      instance.llm_embed('test text', provider: :ollama, dimensions: 1024)
    end

    it 'calls LLM.embed with no kwargs when none are given' do
      expect(Legion::LLM).to receive(:embed).with('bare text')
      instance.llm_embed('bare text')
    end
  end

  describe '#llm_embed_batch' do
    it 'delegates to LLM.embed_batch' do
      texts = %w[hello world]
      expect(Legion::LLM).to receive(:embed_batch).with(texts, model: 'mxbai-embed-large')
      instance.llm_embed_batch(texts, model: 'mxbai-embed-large')
    end
  end

  describe '#llm_session' do
    it 'returns a chat object with layered defaults' do
      allow(instance).to receive(:llm_default_model).and_return('llama3')
      allow(instance).to receive(:llm_default_provider).and_return(:ollama)
      allow(instance).to receive(:llm_default_intent).and_return(nil)

      instance.llm_session
      expect(Legion::LLM).to have_received(:chat).with(
        hash_including(model: 'llama3', provider: :ollama, escalate: false)
      )
    end

    it 'prefers explicit values over defaults' do
      allow(instance).to receive(:llm_default_model).and_return('llama3')

      instance.llm_session(model: 'gpt-4o', provider: :openai)
      expect(Legion::LLM).to have_received(:chat).with(
        hash_including(model: 'gpt-4o', provider: :openai)
      )
    end
  end

  describe '#llm_structured' do
    it 'delegates to LLM.structured' do
      msgs = [{ role: :user, content: 'extract' }]
      schema = { type: 'object', properties: { name: { type: 'string' } } }
      expect(Legion::LLM).to receive(:structured).with(messages: msgs, schema: schema, model: 'gpt-4o')
      instance.llm_structured(messages: msgs, schema: schema, model: 'gpt-4o')
    end
  end

  describe '#llm_ask' do
    it 'delegates to LLM.ask' do
      expect(Legion::LLM).to receive(:ask).with(message: 'hello', model: 'gpt-4o')
      instance.llm_ask(message: 'hello', model: 'gpt-4o')
    end
  end

  describe '#llm_connected?' do
    it 'returns true when LLM is started' do
      allow(Legion::LLM).to receive(:started?).and_return(true)
      expect(instance.llm_connected?).to be true
    end

    it 'returns false when LLM is not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      expect(instance.llm_connected?).to be false
    end
  end

  describe '#llm_can_embed?' do
    it 'returns true when embeddings are available' do
      allow(Legion::LLM).to receive(:started?).and_return(true)
      allow(Legion::LLM).to receive(:can_embed?).and_return(true)
      expect(instance.llm_can_embed?).to be true
    end

    it 'returns false when not connected' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      expect(instance.llm_can_embed?).to be false
    end
  end

  describe '#llm_routing_enabled?' do
    it 'returns true when routing is active' do
      allow(Legion::LLM).to receive(:started?).and_return(true)
      allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(true)
      expect(instance.llm_routing_enabled?).to be true
    end

    it 'returns false when not connected' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      expect(instance.llm_routing_enabled?).to be false
    end
  end

  describe '#llm_cost_estimate' do
    it 'delegates to CostEstimator' do
      allow(Legion::LLM::CostEstimator).to receive(:estimate)
        .with(model_id: 'gpt-4o', input_tokens: 1000, output_tokens: 500)
        .and_return(0.0125)
      expect(instance.llm_cost_estimate(model: 'gpt-4o', input_tokens: 1000, output_tokens: 500)).to eq(0.0125)
    end

    it 'returns 0.0 on error' do
      allow(Legion::LLM::CostEstimator).to receive(:estimate).and_raise(StandardError)
      expect(instance.llm_cost_estimate(model: 'unknown')).to eq(0.0)
    end
  end

  describe '#llm_cost_summary' do
    it 'delegates to CostTracker' do
      summary = { total_cost_usd: 1.5, total_requests: 10, total_input_tokens: 5000,
                  total_output_tokens: 2000, by_model: {} }
      allow(Legion::LLM::CostTracker).to receive(:summary).with(since: nil).and_return(summary)
      expect(instance.llm_cost_summary).to eq(summary)
    end

    it 'returns empty summary on error' do
      allow(Legion::LLM::CostTracker).to receive(:summary).and_raise(StandardError)
      result = instance.llm_cost_summary
      expect(result[:total_cost_usd]).to eq(0.0)
      expect(result[:total_requests]).to eq(0)
    end
  end

  describe '#llm_budget_remaining' do
    it 'delegates to BudgetGuard' do
      allow(Legion::LLM::Hooks::BudgetGuard).to receive(:remaining).and_return(42.5)
      expect(instance.llm_budget_remaining).to eq(42.5)
    end

    it 'returns infinity on error' do
      allow(Legion::LLM::Hooks::BudgetGuard).to receive(:remaining).and_raise(StandardError)
      expect(instance.llm_budget_remaining).to eq(Float::INFINITY)
    end
  end

  describe 'backward compatibility via Extensions::Helpers::LLM' do
    it 'includes all helper methods' do
      ext_class = Class.new { include Legion::Extensions::Helpers::LLM }
      obj = ext_class.new
      expect(obj).to respond_to(:llm_chat, :llm_embed, :llm_embed_batch, :llm_session,
                                :llm_structured, :llm_ask, :llm_connected?, :llm_can_embed?,
                                :llm_cost_estimate, :llm_cost_summary, :llm_budget_remaining,
                                :llm_default_model, :llm_default_provider, :llm_default_intent)
    end
  end
end
