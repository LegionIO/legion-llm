# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/escalation_history'
require 'legion/llm/router/resolution'

RSpec.describe Legion::LLM::EscalationHistory do
  let(:klass) do
    Class.new do
      include Legion::LLM::EscalationHistory

      attr_accessor :content
    end
  end

  let(:response) { klass.new }

  let(:resolution) do
    Legion::LLM::Router::Resolution.new(tier: :cloud, provider: :bedrock, model: 'claude-sonnet-4-6')
  end

  describe '#escalation_history' do
    it 'defaults to empty array' do
      expect(response.escalation_history).to eq([])
    end
  end

  describe '#escalated?' do
    it 'returns false with no history' do
      expect(response.escalated?).to be false
    end

    it 'returns true when history has multiple entries' do
      response.record_escalation_attempt(
        model: 'llama3', provider: :ollama, tier: :local,
        outcome: :error, failures: [], duration_ms: 100
      )
      response.record_escalation_attempt(
        model: 'claude-sonnet-4-6', provider: :bedrock, tier: :cloud,
        outcome: :success, failures: [], duration_ms: 500
      )
      expect(response.escalated?).to be true
    end
  end

  describe '#final_resolution' do
    it 'returns nil when not set' do
      expect(response.final_resolution).to be_nil
    end

    it 'returns the resolution when set' do
      response.final_resolution = resolution
      expect(response.final_resolution.model).to eq('claude-sonnet-4-6')
    end
  end

  describe '#record_escalation_attempt' do
    it 'adds an entry to the history' do
      response.record_escalation_attempt(
        model: 'llama3', provider: :ollama, tier: :local,
        outcome: :quality_failure, failures: [:too_short], duration_ms: 200
      )
      expect(response.escalation_history.size).to eq(1)
      entry = response.escalation_history.first
      expect(entry[:model]).to eq('llama3')
      expect(entry[:outcome]).to eq(:quality_failure)
      expect(entry[:failures]).to eq([:too_short])
    end
  end

  describe '#escalation_chain=' do
    it 'stores the chain for escalate! re-entry' do
      chain = double('EscalationChain')
      response.escalation_chain = chain
      expect(response.escalation_chain).to eq(chain)
    end
  end
end
