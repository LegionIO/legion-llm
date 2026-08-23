# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/routing/filter'

RSpec.describe Legion::LLM::Routing::Filter do
  subject(:router) do
    Class.new do
      include Legion::LLM::Routing::Filter

      # Permissive baseline: no whitelist/blacklist overrides yet.
      def settings
        { body_model_hint_whitelist: [], body_model_hint_blacklist: [] }
      end
    end.new
  end

  describe '#filter_model' do
    it 'returns the trusted model when the X-Legion-Model header is a String' do
      expect(
        router.filter_model(legion_model_header: 'anthropic/claude', legion_trusted_model: 'anthropic/claude')
      ).to eq('anthropic/claude')
    end

    it 'returns the body model when only the body model is a String' do
      expect(router.filter_model(body_model: 'openai/gpt-4')).to eq('openai/gpt-4')
    end

    it 'prefers the trusted model over the body model' do
      expect(
        router.filter_model(
          legion_model_header: 'anthropic/claude',
          legion_trusted_model: 'anthropic/claude',
          body_model: 'openai/gpt-4'
        )
      ).to eq('anthropic/claude')
    end

    it 'returns nil when neither header nor body model is a String' do
      expect(router.filter_model).to be_nil
    end
  end

  describe '#filter_tier' do
    it 'returns the tier when the request constrains it' do
      expect(router.filter_tier(tier: :local)).to eq(:local)
    end

    it 'returns nil when no tier is constrained' do
      expect(router.filter_tier).to be_nil
    end
  end

  describe '#filter_provider' do
    it 'returns the provider when the request constrains it' do
      expect(router.filter_provider(provider: :anthropic)).to eq(:anthropic)
    end

    it 'returns nil when no provider is constrained' do
      expect(router.filter_provider).to be_nil
    end
  end

  describe '#filter_instance' do
    it 'returns the instance when the request constrains it' do
      expect(router.filter_instance(instance: 'h200')).to eq('h200')
    end

    it 'returns nil when no instance is constrained' do
      expect(router.filter_instance).to be_nil
    end
  end

  describe '#filter_context' do
    it 'returns the context size when the request constrains it' do
      expect(router.filter_context(context: 32_000)).to eq(32_000)
    end

    it 'returns nil when no context is constrained' do
      expect(router.filter_context).to be_nil
    end
  end

  describe '#filter_type' do
    it 'returns the type when the request constrains it' do
      expect(router.filter_type(type: :inference)).to eq(:inference)
    end

    it 'returns nil when no type is constrained' do
      expect(router.filter_type).to be_nil
    end
  end

  describe '#filter_embedding_dimensions' do
    it 'returns the dimensions when the request constrains it' do
      expect(router.filter_embedding_dimensions(embedding_dimensions: 1536)).to eq(1536)
    end

    it 'returns nil when no dimensions are constrained' do
      expect(router.filter_embedding_dimensions).to be_nil
    end
  end

  describe '#filter_capability' do
    it 'returns the capabilities when the request requires them' do
      expect(router.filter_capability(capabilities: %i[vision tools])).to eq(%i[vision tools])
    end

    it 'returns nil when no capabilities are required' do
      expect(router.filter_capability).to be_nil
    end
  end

  describe '#filter_availability' do
    it 'returns :available when the instance is available' do
      expect(router.filter_availability(instance: double(availability: double(state: :available)))).to eq(:available)
    end

    it 'returns :unavailable when the instance is unavailable' do
      expect(router.filter_availability(instance: double(availability: double(state: :unavailable)))).to eq(:unavailable)
    end

    it 'returns :unknown when the instance is nil' do
      expect(router.filter_availability(instance: nil)).to eq(:unknown)
    end
  end

  describe '#filter_weight' do
    it 'returns :enabled when all weight inputs are positive' do
      expect(router.filter_weight(lane: double(weight_inputs: { tier: 2, provider: 2 }))).to eq(:enabled)
    end

    it 'returns :disabled when any weight input is zero' do
      expect(router.filter_weight(lane: double(weight_inputs: { tier: 2, provider: 0 }))).to eq(:disabled)
    end
  end

  describe '#filter_fleet' do
    it 'returns :not_applicable for a non-fleet tier' do
      expect(router.filter_fleet(lane: double(tier: :direct, metadata: {}))).to eq(:not_applicable)
    end

    it 'returns :supported for a fleet lane with the exact contract' do
      expect(router.filter_fleet(lane: double(tier: :fleet, metadata: { fleet_execution_contract: 'exact_offering_v1' }))).to eq(:supported)
    end

    it 'returns :legacy for a fleet lane with no contract' do
      expect(router.filter_fleet(lane: double(tier: :fleet, metadata: {}))).to eq(:legacy)
    end
  end

  describe '#filter_policy' do
    it 'returns :allowed when the model passes empty whitelist and blacklist' do
      expect(router.filter_policy(lane: double(model: 'anthropic/claude'), whitelist: [], blacklist: [])).to eq(:allowed)
    end

    it 'returns :denied when the model is blacklisted' do
      expect(router.filter_policy(lane: double(model: 'anthropic/claude'), whitelist: [], blacklist: ['anthropic'])).to eq(:denied)
    end

    it 'returns :denied when the model is not in a non-empty whitelist' do
      expect(router.filter_policy(lane: double(model: 'openai/gpt'), whitelist: ['anthropic'], blacklist: [])).to eq(:denied)
    end
  end
end
