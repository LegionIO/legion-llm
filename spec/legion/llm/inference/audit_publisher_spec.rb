# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::AuditPublisher do
  describe '.build_event' do
    it 'builds event with required fields from request and response' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'req_abc', conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' },
        caller: { requested_by: { identity: 'user:matt', type: :user, credential: :api } }
      )
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }]
      )

      event = described_class.build_event(request: request, response: response)
      expect(event).to be_a(Hash)
      expect(event[:request_id]).to eq('req_abc')
      expect(event[:conversation_id]).to eq('conv_xyz')
      expect(event[:caller]).to eq(response.caller)
      expect(event[:identity]).to eq({ identity: 'user:matt', type: :user, credential: :api })
      expect(event[:tokens]).to be_a(Hash)
      expect(event[:routing]).to eq(response.routing)
      expect(event[:timestamp]).to be_a(Time)
    end

    it 'serializes Data.define tokens to a hash' do
      usage = Data.define(:input_tokens, :output_tokens).new(input_tokens: 100, output_tokens: 20)
      response = Legion::LLM::Inference::Response.build(
        request_id: 'r', conversation_id: 'c',
        message: { role: :assistant, content: 'hi' },
        tokens: usage
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)
      expect(event[:tokens]).to be_a(Hash)
      expect(event[:tokens][:input_tokens]).to eq(100)
      expect(event[:tokens][:output_tokens]).to eq(20)
    end

    it 'includes system_prompt and injected_tools from provider_payload audit' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'r', conversation_id: 'c',
        message: { role: :assistant, content: 'hi' },
        audit: { provider_payload: { system_prompt: 'You are Legion.', injected_tools: %w[tool_a tool_b], tool_count: 2 } }
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)
      expect(event[:system_prompt]).to eq('You are Legion.')
      expect(event[:injected_tools]).to eq(%w[tool_a tool_b])
      expect(event[:audit]).not_to have_key(:provider_payload)
    end

    it 'includes compacted enrichments in event' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'req_abc', conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' },
        enrichments: { 'gaia:advisory' => { content: 'valence summary', data: { valence: [0.3, 0.5, 0.7] } } }
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)
      expect(event[:enrichments]).to have_key('gaia:advisory')
      expect(event[:enrichments]['gaia:advisory'][:data][:valence]).to eq(0.7)
    end

    it 'filters timeline to provider and escalation events only' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'req_abc', conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' },
        timeline: [
          { seq: 1, key: 'tracing:init' },
          { seq: 2, key: 'provider:request_sent', detail: 'streaming from bedrock' },
          { seq: 3, key: 'provider:response_received', detail: 'response received' },
          { seq: 4, key: 'context:stored' }
        ]
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)
      expect(event[:timeline].size).to eq(2)
      expect(event[:timeline].map { |e| e[:key] }).to eq(%w[provider:request_sent provider:response_received])
    end

    it 'includes response_content and messages' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'r', conversation_id: 'c',
        message: { role: :assistant, content: 'answer' }
      )
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'question' }]
      )

      event = described_class.build_event(request: request, response: response)
      expect(event[:response_content]).to eq('answer')
      expect(event[:messages]).to eq([{ role: :user, content: 'question' }])
    end
  end

  describe '.publish' do
    it 'returns event hash even when transport unavailable' do
      response = Legion::LLM::Inference::Response.build(
        request_id: 'req_abc', conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' }
      )
      request = Legion::LLM::Inference::Request.build(messages: [])

      result = described_class.publish(request: request, response: response)
      expect(result).to be_a(Hash)
      expect(result[:request_id]).to eq('req_abc')
    end

    it 'returns nil and does not raise on error' do
      response = double('response')
      allow(response).to receive(:request_id).and_raise(StandardError, 'boom')

      result = described_class.publish(request: double, response: response)
      expect(result).to be_nil
    end
  end
end
