# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Response do
  describe '.build' do
    it 'creates a response with defaults' do
      resp = described_class.build(
        request_id: 'req_abc',
        conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' }
      )
      expect(resp.id).to start_with('resp_')
      expect(resp.request_id).to eq('req_abc')
      expect(resp.schema_version).to eq('1.0.0')
      expect(resp.message[:content]).to eq('hi')
      expect(resp.enrichments).to eq({})
      expect(resp.audit).to eq({})
      expect(resp.timeline).to eq([])
      expect(resp.participants).to eq([])
      expect(resp.frozen?).to eq(true)
    end
  end

  describe '.from_ruby_llm' do
    it 'converts a RubyLLM::Message-like hash to Response' do
      ruby_llm_msg = double(
        content: 'Hello world',
        role: 'assistant',
        input_tokens: 100,
        output_tokens: 20,
        model_id: 'claude-opus-4-6'
      )
      resp = described_class.from_ruby_llm(
        ruby_llm_msg,
        request_id: 'req_abc',
        conversation_id: 'conv_xyz',
        provider: :anthropic,
        model: 'claude-opus-4-6'
      )
      expect(resp.message[:content]).to eq('Hello world')
      expect(resp.tokens[:input]).to eq(100)
      expect(resp.tokens[:output]).to eq(20)
      expect(resp.tokens[:total]).to eq(120)
      expect(resp.routing[:provider]).to eq(:anthropic)
    end
  end

  describe '#with' do
    it 'returns a new response with updated fields' do
      resp = described_class.build(
        request_id: 'req_abc',
        conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' }
      )
      updated = resp.with(warnings: ['test warning'])
      expect(updated.warnings).to eq(['test warning'])
      expect(resp.warnings).to eq([])
    end
  end
end
