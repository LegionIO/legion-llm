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
end
