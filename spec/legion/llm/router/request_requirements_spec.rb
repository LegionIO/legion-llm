# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/request_requirements'

RSpec.describe Legion::LLM::Router::RequestRequirements do
  def request(routing: {}, client_model: nil)
    Legion::LLM::Inference::Request.build_for_test(
      routing_seed: 'ab' * 16, messages: [], routing: routing, client_model: client_model
    )
  end

  def build(req = request, **over)
    described_class.build(
      request: req, operation: :chat, required_capabilities: [], estimated_input_bound: 100,
      required_output_tokens: 50, **over
    )
  end

  it 'computes required_context_budget as input + output' do
    r = build
    expect(r.required_context_budget).to eq(150)
  end

  it 'carries the trusted routing seed from the request context' do
    expect(build.routing_seed).to eq('ab' * 16)
  end

  it 'takes provider/instance/model pins from trusted constraints' do
    r = build(request(routing: { provider: 'vllm', instance: 'h200', model: 'gemma4' }))
    expect(r.provider_pin).to eq(:vllm)
    expect(r.instance_pin).to eq('h200')
    expect(r.model_pin).to eq('gemma4')
  end

  it 'uses the honored body model constraint when there is no trusted model' do
    Legion::Settings.loader.settings[:llm][:routing][:allow_body_routing_hints] = true
    Legion::LLM::Router::SettingsState.reset!
    r = build(request(client_model: 'gemma4'))
    expect(r.model_pin).to eq('gemma4')
  ensure
    Legion::Settings.loader.settings[:llm][:routing][:allow_body_routing_hints] = false
    Legion::LLM::Router::SettingsState.reset!
  end

  it 'has no default provider/model when unconstrained' do
    r = build
    expect(r.provider_pin).to be_nil
    expect(r.model_pin).to be_nil
  end

  it 'derives maximum_attempts and affinity_strength_bps from the settings snapshot' do
    r = build
    expect(r.maximum_attempts).to eq(3)
    expect(r.affinity_strength_bps).to eq(10_000)
  end

  it 'normalizes/dedups required capabilities' do
    r = build(request, required_capabilities: %i[streaming streaming])
    expect(r.required_capabilities).to eq(%i[streaming])
  end

  it 'validates operation, tier, and dimensions' do
    expect { build(request, operation: :nonsense) }.to raise_error(ArgumentError)
    expect { build(request, tier_constraint: :nope) }.to raise_error(ArgumentError)
    expect { build(request, requested_embedding_dimensions: 0) }.to raise_error(ArgumentError)
  end

  it 'rejects duplicate affinity entries and out-of-range scores' do
    dup = [{ source: :gaia, target_kind: :provider, target: :vllm, score_bps: 100 },
           { source: :gaia, target_kind: :provider, target: :vllm, score_bps: 200 }]
    expect { build(request, routing_affinities: dup) }.to raise_error(ArgumentError)
    bad = [{ source: :gaia, target_kind: :provider, target: :vllm, score_bps: 20_000 }]
    expect { build(request, routing_affinities: bad) }.to raise_error(ArgumentError)
  end

  it 'freezes the requirements and nested policy context' do
    r = build(request, policy_context: { privacy: 'normal' })
    expect(r).to be_frozen
    expect(r.policy_context).to be_frozen
    expect(r.policy_context[:privacy]).to eq('normal')
  end
end
