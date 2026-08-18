# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/cache'

# SSOT v3 §20.1: the response-cache identity models the provider+model function,
# built from the EXACT selected lane. It must never include lane_id, offering_id,
# tier, weight, affinity, or routing seed, and identical model strings across
# provider families must never share.
RSpec.describe Legion::LLM::Cache, '.selection_key (SSOT v3 §20.1)' do
  let(:base) do
    {
      provider_family:   :vllm,
      model:             'gemma4',
      revision:          'rev-2026-01',
      operation:         :chat,
      system:            'be helpful',
      messages:          [{ role: 'user', content: 'hi' }],
      tools:             [],
      tool_choice:       { mode: :auto },
      thinking:          nil,
      response_format:   { type: :text },
      max_output_tokens: 4096,
      generation:        { temperature: 0 }
    }
  end

  it 'is deterministic for identical identities' do
    expect(described_class.selection_key(**base)).to eq(described_class.selection_key(**base))
  end

  it 'never shares across provider families for the same model string' do
    other = described_class.selection_key(**base, provider_family: :ollama)
    expect(other).not_to eq(described_class.selection_key(**base))
  end

  it 'shares across instances only with identical authoritative revision evidence' do
    same_rev = described_class.selection_key(**base)
    diff_rev = described_class.selection_key(**base, revision: 'instance:helios1')
    expect(diff_rev).not_to eq(same_rev)
  end

  it 'changes when any semantic request input changes' do
    key = described_class.selection_key(**base)
    expect(described_class.selection_key(**base, messages: [{ role: 'user', content: 'bye' }])).not_to eq(key)
    expect(described_class.selection_key(**base, system: 'be terse')).not_to eq(key)
    expect(described_class.selection_key(**base, tools: [{ name: 't' }])).not_to eq(key)
    expect(described_class.selection_key(**base, tool_choice: { mode: :required })).not_to eq(key)
    expect(described_class.selection_key(**base, thinking: { enabled: true })).not_to eq(key)
    expect(described_class.selection_key(**base, response_format: { type: :json_object })).not_to eq(key)
    expect(described_class.selection_key(**base, max_output_tokens: 1024)).not_to eq(key)
    expect(described_class.selection_key(**base, generation: { temperature: 0, top_p: 0.5 })).not_to eq(key)
    expect(described_class.selection_key(**base, operation: :stream_chat)).not_to eq(key)
  end
end

RSpec.describe Legion::LLM::Inference, '#build_cache_key (SSOT v3 §20.1 default removal)' do
  before do
    Legion::Settings[:llm][:default_model] = 'configured-default-model'
    Legion::Settings[:llm][:default_provider] = :configured_default_provider
  end

  it 'does not inject configured model/provider defaults into the legacy key' do
    with_default = described_class.build_cache_key('explicit-model', :explicit_provider, 'hi', 0)
    without      = described_class.build_cache_key(nil, nil, 'hi', 0)
    # The key with an explicit model/provider differs from the key with none, and
    # the none-key is NOT equal to a key built from the configured defaults.
    injected = described_class.build_cache_key('configured-default-model', :configured_default_provider, 'hi', 0)
    expect(with_default).not_to eq(without)
    expect(without).not_to eq(injected)
  end
end
