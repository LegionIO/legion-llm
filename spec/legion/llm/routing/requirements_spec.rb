# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/routing/requirements'
require 'legion/llm/router'

RSpec.describe Legion::LLM::Routing::Requirements, :ssot_v3 do
  def publish_lane(instance:, capabilities:)
    SsotV3SnapshotFactory.activate(
      provider_family: :vllm, instance_id: instance,
      drafts: [SsotV3SnapshotFactory.offering_draft(
        model: 'test-model', capabilities: capabilities, context: 32_768,
        weight_inputs: { tier: 100, provider: 100, instance: 100, model_or_offering: 100 }, base_weight: 100_000_000
      )]
    )
  end

  it 'routes from captured requirements rather than reinterpreting mutated request data' do
    publish_lane(instance: 'tools', capabilities: { tools: :supported })
    publish_lane(instance: 'text-only', capabilities: { tools: :unsupported })
    tools = [{ name: 'lookup', description: 'Look up a record' }]
    request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'lookup' }], tools: tools)
    requirements = described_class.build(request: request, operation: :chat, body_model: nil)
    tools.clear
    router = Legion::LLM::Router.new(requirements: requirements)

    expect(router.next_lane.instance_id).to eq('tools')
    attempt = router.next_attempt!
    expect(attempt.selection.instance_id).to eq('tools')
    expect(router.next_lane).to be_a(Legion::Extensions::Llm::Routing::Rejection)
  end

  it 'requires tool capability for canonical replay even without fresh tool definitions' do
    publish_lane(instance: 'tools', capabilities: { tools: :supported })
    publish_lane(instance: 'text-only', capabilities: { tools: :unsupported })
    request = Legion::LLM::Inference::Request.build(messages: [
                                                      { role: :assistant, content: '', tool_calls: [{ id: 'call-1', name: 'lookup', arguments: { query: 'status' } }] },
                                                      { role: :tool, tool_call_id: 'call-1', content: 'ready' },
                                                      { role: :user, content: 'summarize' }
                                                    ])
    requirements = described_class.build(request: request, operation: :chat, body_model: nil)

    expect(Legion::LLM::Router.new(requirements: requirements).next_lane.instance_id).to eq('tools')
  end

  it 'uses the ingress settings generation when later settings change the body-model policy' do
    Legion::Settings[:llm][:router][:allow_body_routing_hints] = true
    Legion::LLM::Routing::SettingsState.reset!
    request = Legion::LLM::Inference::Request.build(messages: [])
    Legion::Settings[:llm][:router][:allow_body_routing_hints] = false
    Legion::LLM::Routing::SettingsState.reload!(llm_settings: Legion::Settings[:llm], extension_settings: Legion::Settings[:extensions])
    requirements = described_class.build(request: request, operation: :chat, body_model: 'test-model')

    expect(requirements.model_pin).to eq('test-model')
    expect(requirements.body_model_hint_decision.settings_generation).to eq(request.routing_settings_snapshot.generation)
    next_request = Legion::LLM::Inference::Request.build(messages: [])
    expect(described_class.build(request: next_request, operation: :chat, body_model: 'test-model').model_pin).to be_nil
  end

  it 'rejects malformed internal input before reading Inventory' do
    request = Legion::LLM::Inference::Request.build(messages: [])
    request.messages << { role: :user, content: 'raw internal wire' }

    expect { described_class.build(request: request, operation: :chat, body_model: nil) }.to raise_error(ArgumentError)
    expect { Legion::LLM::Router.new(requirements: {}) }.to raise_error(ArgumentError)
  end
end
