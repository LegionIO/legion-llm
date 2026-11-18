# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/routing/requirements'
require 'legion/llm/router'

RSpec.describe Legion::LLM::Router, :ssot_v3 do
  def publish_lane(instance:, capabilities:)
    SsotV3SnapshotFactory.activate(
      provider_family: :vllm, instance_id: instance,
      drafts: [SsotV3SnapshotFactory.offering_draft(
        model: 'test-model', capabilities: capabilities, context: 32_768,
        weight_inputs: { tier: 100, provider: 100, instance: 100, model_or_offering: 100 }, base_weight: 100_000_000
      )]
    )
  end

  it 'routes from captured request facts rather than reinterpreting mutated request data' do
    publish_lane(instance: 'tools', capabilities: { tools: :supported })
    publish_lane(instance: 'text-only', capabilities: { tools: :unsupported })
    tools = [{ name: 'lookup', description: 'Look up a record' }]
    request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'lookup' }], tools: tools)
    router = described_class.new(request: request, operation: :chat, body_model: nil)
    captured_input_bound = router.input_bound
    captured_context_budget = router.context_budget
    tools.clear
    next_request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'lookup' }], tools: tools)
    next_router = described_class.new(request: next_request, operation: :chat, body_model: nil)

    expect(router.required_capabilities).to eq([:tools])
    expect(router.required_capabilities).to be_frozen
    expect(router.input_bound).to eq(captured_input_bound)
    expect(router.context_budget).to eq(captured_context_budget)
    expect(next_router.required_capabilities).to be_empty
    expect(next_router.input_bound).to be < captured_input_bound
    expect(next_router.context_budget).to be < captured_context_budget

    expect(router.next_lane.instance_id).to eq('tools')
    attempt = router.next_attempt!
    expect(attempt.selection.instance_id).to eq('tools')
    expect(router.next_lane).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    expect(router.attempts_remaining).to eq(router.maximum_attempts - 1)
    expect(router.exclusions).not_to be_empty
    expect(next_router.attempts_remaining).to eq(next_router.maximum_attempts)
    expect(next_router.exclusions).to be_empty
    expect(next_router.consumed_targets).to be_empty
  end

  it 'requires tool capability for canonical replay even without fresh tool definitions' do
    publish_lane(instance: 'tools', capabilities: { tools: :supported })
    publish_lane(instance: 'text-only', capabilities: { tools: :unsupported })
    request = Legion::LLM::Inference::Request.build(messages: [
                                                      { role: :assistant, content: '', tool_calls: [{ id: 'call-1', name: 'lookup', arguments: { query: 'status' } }] },
                                                      { role: :tool, tool_call_id: 'call-1', content: 'ready' },
                                                      { role: :user, content: 'summarize' }
                                                    ])
    router = described_class.new(request: request, operation: :chat, body_model: nil)

    expect(router.next_lane.instance_id).to eq('tools')
  end

  it 'uses the ingress settings generation when later settings change the body-model policy' do
    Legion::Settings[:llm][:router][:allow_body_routing_hints] = true
    Legion::LLM::Routing::SettingsState.reset!
    request = Legion::LLM::Inference::Request.build(messages: [])
    Legion::Settings[:llm][:router][:allow_body_routing_hints] = false
    Legion::LLM::Routing::SettingsState.reload!(llm_settings: Legion::Settings[:llm], extension_settings: Legion::Settings[:extensions])
    router = described_class.new(request: request, operation: :chat, body_model: 'test-model')

    expect(router.model_pin).to eq('test-model')
    expect(router.body_model_hint_decision.settings_generation).to eq(request.routing_settings_snapshot.generation)
    next_request = Legion::LLM::Inference::Request.build(messages: [])
    expect(described_class.new(request: next_request, operation: :chat, body_model: 'test-model').model_pin).to be_nil
  end

  it 'rejects malformed internal input before reading Inventory' do
    request = Legion::LLM::Inference::Request.build(messages: [])
    request.messages << { role: :user, content: 'raw internal wire' }

    expect { described_class.new(request: request, operation: :chat, body_model: nil) }.to raise_error(ArgumentError)
    expect { described_class.new(request: {}, operation: :chat, body_model: nil) }.to raise_error(ArgumentError)
  end
end
