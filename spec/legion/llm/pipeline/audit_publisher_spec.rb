# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::AuditPublisher do
  describe '.build_event' do
    it 'builds event with required fields from request and response' do
      response = Legion::LLM::Pipeline::Response.build(
        request_id: 'req_abc', conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' },
        caller: { requested_by: { identity: 'user:matt', type: :user } }
      )
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'hello' }]
      )

      event = described_class.build_event(request: request, response: response)
      expect(event).to be_a(Hash)
      expect(event[:request_id]).to eq('req_abc')
      expect(event[:conversation_id]).to eq('conv_xyz')
      expect(event[:caller]).to eq(response.caller)
      expect(event[:tokens]).to eq(response.tokens)
      expect(event[:routing]).to eq(response.routing)
      expect(event[:timestamp]).to be_a(Time)
    end

    it 'includes enrichments and timeline in event' do
      response = Legion::LLM::Pipeline::Response.build(
        request_id: 'req_abc', conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' },
        enrichments: { 'gaia:advisory' => { data: { valence: [0.5] } } },
        timeline: [{ seq: 1, key: 'test' }]
      )
      request = Legion::LLM::Pipeline::Request.build(messages: [])

      event = described_class.build_event(request: request, response: response)
      expect(event[:enrichments]).to have_key('gaia:advisory')
      expect(event[:timeline]).not_to be_empty
    end

    it 'includes response_content and messages' do
      response = Legion::LLM::Pipeline::Response.build(
        request_id: 'r', conversation_id: 'c',
        message: { role: :assistant, content: 'answer' }
      )
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'question' }]
      )

      event = described_class.build_event(request: request, response: response)
      expect(event[:response_content]).to eq('answer')
      expect(event[:messages]).to eq([{ role: :user, content: 'question' }])
    end
  end

  describe '.publish' do
    it 'returns event hash even when transport unavailable' do
      response = Legion::LLM::Pipeline::Response.build(
        request_id: 'req_abc', conversation_id: 'conv_xyz',
        message: { role: :assistant, content: 'hi' }
      )
      request = Legion::LLM::Pipeline::Request.build(messages: [])

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
