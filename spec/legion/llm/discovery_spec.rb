# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Discovery do
  before do
    described_class.reset!
    Legion::LLM::Call::Registry.reset!
  end

  it 'normalizes lex-llm ModelOffering objects from registry adapters' do
    offering = Legion::Extensions::Llm::Routing::ModelOffering.new(
      provider_family: :vllm,
      instance_id:     :apollo,
      tier:            :direct,
      model:           'qwen3.6-27b',
      usage_type:      :inference,
      capabilities:    %i[chat streaming],
      limits:          { context_window: 131_072 },
      metadata:        { parameter_count: 27_000_000_000 }
    )
    adapter = Class.new do
      define_method(:offerings) { |live: false| live ? [offering] : [] }
    end.new

    Legion::LLM::Call::Registry.register(:vllm, adapter, instance: :apollo, metadata: { tier: :direct })

    discovered = described_class.discovered_models

    expect(discovered).to contain_exactly(
      include(
        model:           'qwen3.6-27b',
        provider:        :vllm,
        instance:        :apollo,
        tier:            :direct,
        capabilities:    %i[chat streaming],
        context_length:  131_072,
        parameter_count: 27_000_000_000
      )
    )
  end
end
