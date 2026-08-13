# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM.chat router integration' do
  before do
    stub_native_provider(content: 'pipeline response')
  end

  describe 'explicit provider and model pass-through' do
    it 'routes to explicit provider and model when both are registered in the SSOT inventory' do
      # SSOT v3: when provider + model are registered via the Phase 1 Registry,
      # the router selects that exact lane. Verify the response routing reflects them.
      write_test_lane(provider: :vllm, model: SSOT_TEST_MODEL, type: :inference)

      result = Legion::LLM.chat(model: SSOT_TEST_MODEL, provider: :vllm, message: 'hello')

      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.routing[:provider]).to eq(:vllm)
      expect(result.routing[:model]).to eq(SSOT_TEST_MODEL)
    end
  end

  describe 'any-provider selection when no explicit pin is given' do
    it 'selects a provider from the registry and returns a Response' do
      # No explicit provider or model pin — the router picks from all available lanes.
      result = Legion::LLM.chat(message: 'hello')

      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.routing).to include(:provider)
      expect(result.routing[:model]).to eq(SSOT_TEST_MODEL)
    end
  end

  describe 'tier override' do
    it 'selects a lane in the requested tier when it is available' do
      # Register a frontier-tier lane for explicit selection.
      write_test_lane(provider: :anthropic, model: SSOT_TEST_MODEL, tier: :frontier, type: :inference)

      result = Legion::LLM.chat(tier: :frontier, model: SSOT_TEST_MODEL, provider: :anthropic, message: 'hello')

      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.routing[:tier]).to eq(:frontier)
    end
  end

  describe 'routing when no matching lanes are available' do
    it 'raises RoutingRejected when the pinned model is not published in the SSOT Registry' do
      # Clear registry so no lanes are available for 'nonexistent-model'.
      Legion::Extensions::Llm::Inventory::Registry.reset!

      expect do
        Legion::LLM.chat(model: 'nonexistent-model', provider: :vllm, message: 'hello')
      end.to raise_error(Legion::LLM::Errors::RoutingRejected)
    end
  end
end
