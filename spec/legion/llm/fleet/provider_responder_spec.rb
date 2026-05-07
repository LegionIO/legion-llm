# frozen_string_literal: true

require 'spec_helper'

class FleetResponderSpecProvider
  attr_reader :config

  def initialize(config)
    @config = config
  end
end

RSpec.describe Legion::LLM::Fleet::ProviderResponder do
  let(:payload) do
    {
      protocol_version:  2,
      request_id:        'req-provider',
      correlation_id:    'corr-provider',
      idempotency_key:   'idem-provider',
      operation:         'chat',
      provider:          'ollama',
      provider_instance: 'local',
      model:             'llama3.2',
      params:            { messages: [{ role: 'user', content: 'hello' }] },
      reply_to:          'llm.fleet.reply.test',
      message_context:   { conversation_id: 'conv-1' },
      caller:            { source: 'spec' },
      trace_context:     { trace_id: 'trace-1' },
      signed_token:      'signed-token',
      timeout_seconds:   15,
      expires_at:        '2026-05-06T12:00:00Z'
    }
  end

  let(:provider_instances) do
    {
      local: {
        api_base: 'http://localhost:11434',
        fleet:    { respond_to_requests: true, capabilities: %i[chat embed] }
      }
    }
  end

  before do
    Legion::Settings[:llm][:fleet] = { consumer: { requeue_transient: true }, responder: { require_auth: false } }
    allow(Legion::Extensions::Llm::Transport::Messages::FleetResponse).to receive(:new)
      .and_return(instance_double(Legion::Extensions::Llm::Transport::Messages::FleetResponse, publish: true))
    allow(Legion::Extensions::Llm::Transport::Messages::FleetError).to receive(:new)
      .and_return(instance_double(Legion::Extensions::Llm::Transport::Messages::FleetError, publish: true))
  end

  it 'validates the fleet envelope, resolves the provider instance, executes through WorkerExecution, publishes response, and acks' do
    delivery = instance_double('Delivery', ack: true)
    response = Legion::Extensions::Llm::Responses::ChatResponse.new(
      content: 'hello back',
      model:   'llama3.2',
      tokens:  { input_tokens: 2, output_tokens: 3 }
    )

    expect(Legion::LLM::Fleet::WorkerExecution).to receive(:call).with(
      envelope: have_attributes(operation: 'chat', provider_instance: 'local'),
      provider: instance_of(FleetResponderSpecProvider)
    ).and_return(response)

    result = described_class.call(
      payload:            Legion::JSON.dump(payload),
      provider_family:    :ollama,
      provider_class:     FleetResponderSpecProvider,
      provider_instances: provider_instances,
      delivery:           delivery
    )

    expect(result).to eq(response)
    expect(delivery).to have_received(:ack)
    expect(Legion::Extensions::Llm::Transport::Messages::FleetResponse).to have_received(:new).with(
      hash_including(
        request_id:        'req-provider',
        correlation_id:    'corr-provider',
        idempotency_key:   'idem-provider',
        operation:         'chat',
        provider:          'ollama',
        provider_instance: 'local',
        model:             'llama3.2',
        reply_to:          'llm.fleet.reply.test',
        content:           'hello back',
        usage:             { input_tokens: 2, output_tokens: 3 }
      )
    )
  end

  it 'publishes a non-retryable fleet error and rejects without requeue when policy validation fails' do
    delivery = instance_double('Delivery', reject: true)
    error = Legion::LLM::Fleet::WorkerExecution::PolicyError.new('bad token')

    allow(Legion::LLM::Fleet::WorkerExecution).to receive(:call).and_raise(error)

    expect do
      described_class.call(
        payload:            payload,
        provider_family:    :ollama,
        provider_class:     FleetResponderSpecProvider,
        provider_instances: provider_instances,
        delivery:           delivery
      )
    end.to raise_error(Legion::LLM::Fleet::WorkerExecution::PolicyError, /bad token/)

    expect(delivery).to have_received(:reject).with(false)
    expect(Legion::Extensions::Llm::Transport::Messages::FleetError).to have_received(:new).with(
      hash_including(code: 'policy_error', message: 'bad token', retryable: false)
    )
  end
end
