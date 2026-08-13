# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/routing_context'

RSpec.describe Legion::LLM::RoutingContext do
  describe '.build' do
    it 'produces a 32-char lowercase hex seed' do
      ctx = described_class.build
      expect(ctx.routing_seed).to match(/\A[0-9a-f]{32}\z/)
    end

    it 'produces distinct seeds across calls' do
      seeds = Array.new(50) { described_class.build.routing_seed }
      expect(seeds.uniq.size).to eq(50)
    end

    it 'freezes the context and the seed' do
      ctx = described_class.build
      expect(ctx).to be_frozen
      expect(ctx.routing_seed).to be_frozen
    end
  end

  describe 'the ordinary constructor' do
    it 'is private (no client/body/header path can build one)' do
      expect { described_class.new(routing_seed: 'a' * 32) }.to raise_error(NoMethodError)
    end
  end

  describe '.for_test' do
    it 'accepts a valid injected seed under RSpec' do
      ctx = described_class.for_test(routing_seed: 'ab' * 16)
      expect(ctx.routing_seed).to eq('ab' * 16)
    end

    it 'rejects a malformed seed with InvalidRoutingContext' do
      expect { described_class.for_test(routing_seed: 'NOTHEX') }
        .to raise_error(Legion::LLM::Errors::InvalidRoutingContext)
      expect { described_class.for_test(routing_seed: 'A' * 32) } # uppercase not allowed
        .to raise_error(Legion::LLM::Errors::InvalidRoutingContext)
      expect { described_class.for_test(routing_seed: 'ab' * 8) } # too short
        .to raise_error(Legion::LLM::Errors::InvalidRoutingContext)
    end
  end
end
