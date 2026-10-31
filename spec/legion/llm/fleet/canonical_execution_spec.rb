# frozen_string_literal: true

require 'spec_helper'
require 'legion/crypt'
require 'legion/crypt/jwt'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_chat'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/extensions/llm/vllm'
require 'legion/extensions/llm/openai'
require 'legion/extensions/llm/vllm/helpers/callable'
require 'legion/extensions/llm/openai/helpers/callable'
require 'legion/extensions/llm/fleet/worker_execution'

RSpec.describe 'Canonical exact execution across clients, providers and fleet', :ssot_v3 do
  let(:model) { 'vision-model' }
  let(:image_url) { 'https://example.com/image.png' }
  let(:data_url) { 'data:image/png;base64,QUJD' }
  let(:wire_requests) { [] }
  let(:worker) { Legion::Extensions::Llm::Fleet::WorkerExecution }

  before do
    allow(Legion::Crypt).to receive(:cluster_secret).and_return('offline-fleet-signing-key-0123456789')
    Legion::Settings[:llm][:fleet][:dispatch][:require_auth] = true
    Legion::Settings[:extensions][:llm][:fleet] = {
      responder: { require_auth: true, require_idempotency: true, require_policy: false }
    }
    Legion::Extensions::Llm::Fleet::TokenValidator.reset_replay_cache!
    worker.reset_idempotency_cache!
  end

  def client_requests
    text = { type: 'text', text: 'compare' }
    anthro_images = [
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'QUJD' } },
      { type: 'image', source: { type: 'url', url: image_url } }
    ]
    chat_images = [data_url, image_url].map { |url| { type: 'image_url', image_url: { url: url } } }
    response_images = [data_url, image_url].map { |url| { type: 'input_image', image_url: url } }
    translators = Legion::LLM::API::ClientTranslators
    [
      [translators::AnthropicMessages.new, { messages: [{ role: 'user', content: [text, *anthro_images] }] }],
      [translators::OpenAIChat.new, { messages: [{ role: 'user', content: [text, *chat_images] }] }],
      [translators::OpenAIResponses.new, { input: [{ role: 'user', content: [text, *response_images] }] }]
    ].map do |translator, body|
      canonical = translator.parse_request(body, {})
      translator.build_inference_request(canonical, request_id: SecureRandom.uuid, server_caller: { source: 'test' })
    end
  end

  def activate_callable(provider_family:)
    callable = case provider_family
               when :vllm
                 Legion::Extensions::Llm::Vllm::Helpers::Callable.new(
                   instance_cfg: { name: 'primary', vllm_api_base: 'https://vision.example', tier: :local },
                   logger:       Logger.new(File::NULL)
                 )
               when :openai
                 Legion::Extensions::Llm::Openai::Helpers::Callable.new(
                   instance_cfg: { name: 'primary', openai_api_base: 'https://vision.example', openai_api_key: 'offline-test-key' },
                   logger:       Logger.new(File::NULL)
                 )
               end
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post('/v1/chat/completions') do |env|
        wire_requests << Legion::JSON.load(env.body)
        body = { model: model, choices: [{ message: { role: 'assistant', content: 'image understood' }, finish_reason: 'stop' }],
                 usage: { prompt_tokens: 7, completion_tokens: 2 } }
        [200, { 'content-type' => 'application/json' }, Legion::JSON.dump(body)]
      end
    end
    callable.send(:provider).connection.connection.builder.adapter :test, stubs
    SsotV3SnapshotFactory.activate(
      provider_family: provider_family, instance_id: 'primary', callable: callable,
      drafts: [SsotV3SnapshotFactory.offering_draft(
        model: model, capabilities: { vision: :supported }, context: 32_768, max_output: 8192,
        weight_inputs: { tier: 100, provider: 100, instance: 100, model_or_offering: 100 }, base_weight: 100_000_000
      )]
    )
    stubs
  end

  def execution_for(request:)
    requirements = Legion::LLM::Routing::Requirements.build(request: request, operation: :chat, body_model: nil)
    router = Legion::LLM::Router.new(requirements: requirements)
    attempt = router.next_attempt!
    executor = Legion::LLM::Inference::Executor.new(request)
    executor.send(:populate_ssot_v3_resolved_state, attempt)
    binding = executor.send(:fleet_dispatch_request, request.messages, SecureRandom.uuid, dispatch_options: {})
    envelope = Legion::LLM::Fleet::Dispatcher.build_envelope(
      operation: attempt.selection.operation, request_opts: binding,
      message_context: { request_id: request.id }, reply_to: 'llm.fleet.reply.test', routing_key: 'llm.test'
    )
    [attempt, Legion::JSON.load(Legion::JSON.dump(envelope))]
  end

  %i[vllm openai].each do |provider_family|
    it "preserves all three client dialects through exact direct and signed fleet execution on #{provider_family}" do
      stubs = activate_callable(provider_family: provider_family)
      client_requests.each do |request|
        attempt, envelope = execution_for(request: request)
        direct = Legion::LLM::Call::SelectionDispatch.call(attempt_context: attempt, arguments: { messages: request.messages })
        remote = worker.call(envelope: envelope, registry: Legion::Extensions::Llm::Inventory::Registry)

        expect(direct).to be_success
        expect(direct.value.text).to eq('image understood')
        expect(remote.text).to eq(direct.value.text)
        expect(wire_requests.last(2).map { |wire| wire[:model] }).to eq([model, model])
        expect(wire_requests.last(2).map { |wire| wire[:messages] }).to eq([
          [{ role: 'user', content: [
            { type: 'text', text: 'compare' },
            { type: 'image_url', image_url: { url: data_url } },
            { type: 'image_url', image_url: { url: image_url } }
          ] }]
        ] * 2)
      end
      stubs.verify_stubbed_calls
    end
  end

  it 'rejects signed binding and media tampering before any provider invocation' do
    activate_callable(provider_family: :vllm)
    _attempt, envelope = execution_for(request: client_requests.first)
    bad_model = Legion::JSON.load(Legion::JSON.dump(envelope))
    bad_model[:model] = 'other-model'
    bad_media = Legion::JSON.load(Legion::JSON.dump(envelope))
    bad_media[:params][:messages].first[:content][1][:data] = 'REVG'

    expect { worker.call(envelope: bad_model, registry: Legion::Extensions::Llm::Inventory::Registry) }
      .to raise_error(worker::PolicyError)
    expect { worker.call(envelope: bad_media, registry: Legion::Extensions::Llm::Inventory::Registry) }
      .to raise_error(worker::PolicyError)
    expect(wire_requests).to be_empty
  end

  it 'rejects an authenticated exact binding that disagrees with current Inventory' do
    activate_callable(provider_family: :vllm)
    _attempt, envelope = execution_for(request: client_requests.first)
    envelope[:model] = 'other-model'
    envelope[:signed_token] = Legion::LLM::Fleet::TokenIssuer.issue(envelope)

    expect { worker.call(envelope: envelope, registry: Legion::Extensions::Llm::Inventory::Registry) }
      .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    expect(wire_requests).to be_empty
  end
end
