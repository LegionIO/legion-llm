# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/namespaces/anthropic/models'

RSpec.describe Legion::LLM::API::Namespaces::Anthropic::Models do
  let(:offerings) do
    [
      { model: 'claude-sonnet-4-6', type: :inference, provider_family: 'anthropic', instance_id: 'default',
        capabilities: %w[chat tools], limits: { context_window: 200_000 }, enabled: true },
      { model: 'llama3', type: :inference, provider_family: 'ollama', instance_id: 'local',
        capabilities: %w[chat], limits: { context_window: 8192 }, enabled: true }
    ]
  end

  describe '.format_model_list' do
    it 'returns Anthropic paginated list shape' do
      result = described_class.format_model_list(offerings)
      expect(result[:data]).to be_an(Array)
      expect(result).to have_key(:has_more)
      expect(result).to have_key(:first_id)
      expect(result).to have_key(:last_id)
    end

    it 'deduplicates by model id' do
      duped = offerings + [offerings.first]
      result = described_class.format_model_list(duped)
      ids = result[:data].map { |m| m[:id] }
      expect(ids.uniq).to eq(ids)
    end

    it 'formats each model with required Anthropic fields' do
      result = described_class.format_model_list(offerings)
      model = result[:data].first
      expect(model[:type]).to eq('model')
      expect(model).to have_key(:id)
      expect(model).to have_key(:display_name)
      expect(model).to have_key(:created_at)
    end
  end

  describe '.format_model' do
    it 'formats a single model in Anthropic shape' do
      result = described_class.format_model(offerings.first)
      expect(result[:id]).to eq('claude-sonnet-4-6')
      expect(result[:type]).to eq('model')
      expect(result).to have_key(:display_name)
      expect(result).to have_key(:created_at)
    end
  end
end
