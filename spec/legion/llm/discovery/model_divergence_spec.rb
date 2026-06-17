# frozen_string_literal: true

require 'spec_helper'

# Guardrail: Discovery warns when an instance's live discovered models don't
# include its configured default_model — surfaces a stale/misconfigured backend
# (the apollo-0001 case: configured gemma-4-12b-it, still serving qwen3.6-27b
# because the vLLM service hadn't been restarted, behind an HAProxy pool).
RSpec.describe 'Legion::LLM::Discovery model-divergence warning' do
  before { Legion::LLM::Discovery.reset! }

  def stub_single_instance(default_model:, discovered_model:)
    adapter = instance_double('adapter')
    allow(adapter).to receive(:offerings).with(live: true).and_return([{ id: discovered_model }])
    allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return(
      [{ provider: :vllm, instance: :v100, adapter: adapter, metadata: { default_model: default_model, tier: :direct } }]
    )
    allow(Legion::LLM::Discovery.log).to receive(:warn)
  end

  it 'warns when the discovered model diverges from the configured default_model' do
    stub_single_instance(default_model: 'gemma-4-12b-it', discovered_model: 'qwen3.6-27b')

    Legion::LLM::Discovery.refresh_provider_models(:vllm)

    expect(Legion::LLM::Discovery.log).to have_received(:warn)
      .with(/model_divergence.*instance=v100.*configured=gemma-4-12b-it.*discovered=qwen3\.6-27b/)
  end

  it 'does not warn when the discovered model matches the configured default_model' do
    stub_single_instance(default_model: 'gemma-4-12b-it', discovered_model: 'gemma-4-12b-it')

    Legion::LLM::Discovery.refresh_provider_models(:vllm)

    expect(Legion::LLM::Discovery.log).not_to have_received(:warn).with(/model_divergence/)
  end

  it 'does not warn when the instance has no configured default_model' do
    adapter = instance_double('adapter')
    allow(adapter).to receive(:offerings).with(live: true).and_return([{ id: 'qwen3.6-27b' }])
    allow(Legion::LLM::Call::Registry).to receive(:all_instances).and_return(
      [{ provider: :vllm, instance: :v100, adapter: adapter, metadata: { tier: :direct } }]
    )
    allow(Legion::LLM::Discovery.log).to receive(:warn)

    Legion::LLM::Discovery.refresh_provider_models(:vllm)

    expect(Legion::LLM::Discovery.log).not_to have_received(:warn).with(/model_divergence/)
  end
end
