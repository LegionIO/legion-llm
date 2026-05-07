# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Fleet::Handler do
  let(:envelope) do
    {
      protocol_version:  2,
      request_id:        'req-handler',
      correlation_id:    'corr-handler',
      idempotency_key:   'idem-handler',
      operation:         :chat,
      provider:          'ollama',
      provider_instance: 'default',
      model:             'llama3.2',
      params:            { messages: [{ role: 'user', content: 'hello' }] },
      reply_to:          'llm.fleet.reply.test',
      message_context:   { conversation_id: 'conv-1' },
      caller:            { source: 'test' },
      trace_context:     { trace_id: 'trace-1' },
      signed_token:      'signed-token',
      timeout_seconds:   30,
      expires_at:        (Time.now.utc + 30).iso8601
    }
  end

  describe '.handle_fleet_request' do
    it 'executes a strict protocol-v2 request through WorkerExecution and publishes a FleetResponse' do
      response = Legion::Extensions::Llm::Responses::ChatResponse.new(
        content: 'hello back',
        model:   'llama3.2',
        tokens:  { input: 3, output: 2 }
      )
      provider = instance_double('Provider')
      message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetResponse, publish: { accepted: true })
      resolver = nil

      allow(described_class).to receive(:resolve_provider).with(envelope).and_return(provider)
      allow(Legion::LLM::Fleet::WorkerExecution).to receive(:call)
        .with(envelope: envelope, provider: an_object_satisfying { |object|
          resolver = object
          object.respond_to?(:call)
        })
        .and_wrap_original do |_original, envelope:, provider:|
          provider.call(envelope)
          response
        end

      expect(Legion::Extensions::Llm::Transport::Messages::FleetResponse).to receive(:new).with(
        hash_including(
          protocol_version:  2,
          request_id:        'req-handler',
          correlation_id:    'corr-handler',
          idempotency_key:   'idem-handler',
          operation:         :chat,
          provider:          'ollama',
          provider_instance: 'default',
          model:             'llama3.2',
          reply_to:          'llm.fleet.reply.test',
          message_context:   { conversation_id: 'conv-1' },
          content:           'hello back',
          usage:             { input: 3, output: 2 }
        )
      ).and_return(message)

      result = described_class.handle_fleet_request(envelope)

      expect(result[:success]).to eq(true)
      expect(result[:content]).to eq('hello back')
      expect(resolver).not_to be_nil
      expect(message).to have_received(:publish).with(
        hash_including(
          mandatory:                  false,
          publisher_confirm:          false,
          publish_confirm_timeout_ms: 500,
          spool:                      false,
          return_result:              true
        )
      )
    end

    it 'publishes FleetError when protocol validation fails' do
      message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetError, publish: { accepted: true })

      expect(Legion::Extensions::Llm::Transport::Messages::FleetError).to receive(:new).with(
        hash_including(
          protocol_version: 2,
          request_id:       'req-handler',
          correlation_id:   'corr-handler',
          reply_to:         'llm.fleet.reply.test',
          code:             'invalid_fleet_request'
        )
      ).and_return(message)

      result = described_class.handle_fleet_request(envelope.except(:operation))

      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('invalid_fleet_request')
      expect(message).to have_received(:publish)
    end

    it 'rejects malformed protocol versions that coerce to v2' do
      message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetError, publish: { accepted: true })
      allow(Legion::Extensions::Llm::Transport::Messages::FleetError).to receive(:new).and_return(message)

      result = described_class.handle_fleet_request(envelope.merge(protocol_version: '2junk'))

      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('invalid_fleet_request')
    end

    it 'does not resolve providers before WorkerExecution validates identity and policy' do
      allow(Legion::LLM::Fleet::WorkerExecution).to receive(:call)
        .and_raise(Legion::LLM::Fleet::WorkerExecution::PolicyError, 'bad token')

      expect(described_class).not_to receive(:resolve_provider)

      result = described_class.handle_fleet_request(envelope)

      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('fleet_policy_denied')
    end

    it 'rejects protocol-v2 requests missing full shared request envelope fields' do
      message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetError, publish: { accepted: true })
      allow(Legion::Extensions::Llm::Transport::Messages::FleetError).to receive(:new).and_return(message)

      result = described_class.handle_fleet_request(envelope.except(:caller))

      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('invalid_fleet_request')
      expect(message).to have_received(:publish)
    end

    it 'rejects legacy protocol-v1 fleet fields on inbound worker requests' do
      message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetError, publish: { accepted: true })
      allow(Legion::Extensions::Llm::Transport::Messages::FleetError).to receive(:new).and_return(message)

      result = described_class.handle_fleet_request(envelope.merge(request_type: 'chat'))

      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('invalid_fleet_request')
      expect(result[:message]).to include('request_type')
    end

    it 'allows unsigned inbound requests when responder auth is disabled' do
      response = { content: 'hello back', usage: { input: 3, output: 2 } }
      message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetResponse, publish: { accepted: true })

      Legion::Settings[:llm][:fleet] = { responder: { require_auth: false } }
      allow(Legion::LLM::Fleet::WorkerExecution).to receive(:call).and_return(response)
      allow(Legion::Extensions::Llm::Transport::Messages::FleetResponse).to receive(:new).and_return(message)

      result = described_class.handle_fleet_request(envelope.except(:signed_token))

      expect(result[:success]).to eq(true)
      expect(Legion::LLM::Fleet::WorkerExecution).to have_received(:call)
    end

    it 'inherits responder auth from shared fleet auth policy when responder override is unset' do
      response = { content: 'hello back', usage: { input: 3, output: 2 } }
      message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetResponse, publish: { accepted: true })

      Legion::Settings[:llm][:fleet] = { auth: { require_signed_token: false } }
      allow(Legion::LLM::Fleet::WorkerExecution).to receive(:call).and_return(response)
      allow(Legion::Extensions::Llm::Transport::Messages::FleetResponse).to receive(:new).and_return(message)

      result = described_class.handle_fleet_request(envelope.except(:signed_token))

      expect(result[:success]).to eq(true)
      expect(Legion::LLM::Fleet::WorkerExecution).to have_received(:call)
    end
  end
end
