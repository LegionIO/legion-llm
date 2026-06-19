# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Router::Availability do
  before do
    Legion::LLM::Router.reset!
    Legion::LLM::Discovery.reset!
    # Seed provider settings so write_lane can compute lane_weight
    Legion::Settings[:extensions][:llm][:vllm] ||= { weight: 100, instances: {}, models: {} }
    Legion::Settings[:extensions][:llm][:bedrock] ||= { weight: 100, instances: {}, models: {} }
    # Seed Inventory lanes so HealthTracker writes are visible to rejection_reason
    Legion::LLM::Inventory.write_lane(
      lane: { id: 'fleet:vllm:h200:inference:qwen3-32b', tier: :fleet, provider_family: :vllm,
              instance_id: :h200, model: 'qwen3-32b', type: :inference },
      ttl:  3600
    )
    Legion::LLM::Inventory.write_lane(
      lane: { id: 'cloud:bedrock:primary:inference:anthropic.claude-sonnet-4', tier: :cloud,
              provider_family: :bedrock, instance_id: :primary,
              model: 'anthropic.claude-sonnet-4', type: :inference },
      ttl:  3600
    )
  end

  let(:vllm_resolution) do
    Legion::LLM::Router::Resolution.new(
      tier: :fleet, provider: :vllm, instance: :h200,
      model: 'qwen3-32b', offering_id: 'vllm-h200-qwen',
      metadata: { capabilities: %i[completion streaming tools] }
    )
  end

  let(:bedrock_resolution) do
    Legion::LLM::Router::Resolution.new(
      tier: :cloud, provider: :bedrock, instance: :primary,
      model: 'anthropic.claude-sonnet-4', offering_id: 'bedrock-sonnet',
      metadata: { capabilities: %i[completion streaming tools] }
    )
  end

  let(:bedrock_offering) do
    {
      model:           'anthropic.claude-sonnet-4',
      provider_family: 'bedrock',
      instance_id:     'primary',
      capabilities:    %w[chat completion streaming tools],
      limits:          { context_window: 200_000 }
    }
  end

  let(:vllm_offering) do
    {
      model:           'qwen3-32b',
      provider_family: 'vllm',
      instance_id:     'h200',
      capabilities:    %w[chat completion streaming tools],
      limits:          { context_window: 32_768 }
    }
  end

  before do
    allow(Legion::LLM::Inventory).to receive(:offerings).and_call_original
    allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :bedrock)).and_return([bedrock_offering])
    allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :vllm)).and_return([vllm_offering])
    allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :ollama)).and_return([])
    allow(Legion::LLM::Inventory).to receive(:offerings).with(hash_including(provider: :anthropic)).and_return([])
  end
end
