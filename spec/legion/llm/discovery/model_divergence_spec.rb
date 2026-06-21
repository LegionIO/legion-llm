# frozen_string_literal: true

require 'spec_helper'

# Guardrail: Discovery warns when an instance's live discovered models don't
# include its configured default_model — surfaces a stale/misconfigured backend.
RSpec.describe 'Legion::LLM::Discovery model-divergence warning' do
  before { Legion::LLM::Discovery.reset! }

  def fetch_with(provider:, instance:, default_model:, discovered_models:)
    adapter = instance_double('adapter')
    allow(adapter).to receive(:offerings).with(live: true).and_return(discovered_models.map { |id| { id: id } })
    entry = { provider: provider, instance: instance, adapter: adapter,
              metadata: { default_model: default_model, tier: :direct } }
    allow(Legion::LLM::Discovery.log).to receive(:warn)
    Legion::LLM::Inventory::Discovery.send(:fetch_offering_models, entry)
  end

  it 'warns when the discovered model diverges from the configured default_model' do
    fetch_with(provider: :vllm, instance: :v100, default_model: 'gemma-4-12b-it',
               discovered_models: ['qwen3.6-27b'])

    expect(Legion::LLM::Discovery.log).to have_received(:warn)
      .with(/model_divergence.*instance=v100.*configured=gemma-4-12b-it.*discovered=qwen3\.6-27b/)
  end

  it 'does not warn when the discovered model matches the configured default_model' do
    fetch_with(provider: :vllm, instance: :v100, default_model: 'gemma-4-12b-it',
               discovered_models: ['gemma-4-12b-it'])

    expect(Legion::LLM::Discovery.log).not_to have_received(:warn).with(/model_divergence/)
  end

  it 'does not warn when the instance has no configured default_model' do
    adapter = instance_double('adapter')
    allow(adapter).to receive(:offerings).with(live: true).and_return([{ id: 'qwen3.6-27b' }])
    allow(Legion::LLM::Discovery.log).to receive(:warn)
    entry = { provider: :vllm, instance: :v100, adapter: adapter, metadata: { tier: :direct } }
    Legion::LLM::Inventory::Discovery.send(:fetch_offering_models, entry)

    expect(Legion::LLM::Discovery.log).not_to have_received(:warn).with(/model_divergence/)
  end

  it 'does not warn when a discovered id is a versioned family member of the configured default' do
    fetch_with(
      provider: :bedrock, instance: :claude, default_model: 'anthropic.claude-sonnet-4',
      discovered_models: ['anthropic.claude-sonnet-4-6', 'anthropic.claude-sonnet-4-20250514-v1:0',
                          'anthropic.claude-opus-4-8', 'amazon.nova-pro-v1:0']
    )

    expect(Legion::LLM::Discovery.log).not_to have_received(:warn).with(/model_divergence/)
  end

  it 'truncates the discovered list and reports a count when warning on a large catalog' do
    fetch_with(provider: :bedrock, instance: :claude, default_model: 'anthropic.claude-sonnet-4',
               discovered_models: (1..30).map { |n| "vendor.model-#{n}" })

    expect(Legion::LLM::Discovery.log).to have_received(:warn)
      .with(/model_divergence.*discovered_count=30 discovered=.*,\+20 more/)
  end
end
