# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/hooks'
require 'legion/llm/hooks/metering'

RSpec.describe Legion::LLM::Hooks::Metering do
  after { Legion::LLM::Hooks.reset! }

  describe '.install' do
    it 'registers an after_chat hook' do
      expect { described_class.install }.to change {
        Legion::LLM::Hooks.instance_variable_get(:@after_chat).size
      }.by(1)
    end
  end

  describe '.extract_metering_data' do
    it 'extracts usage from a response hash' do
      response = {
        content: 'hello',
        usage:   { input_tokens: 100, output_tokens: 50 },
        meta:    { provider: 'anthropic', model: 'claude-opus-4-6' }
      }
      data = described_class.extract_metering_data(response, 'claude-opus-4-6')
      expect(data[:input_tokens]).to eq(100)
      expect(data[:output_tokens]).to eq(50)
      expect(data[:provider]).to eq('anthropic')
      expect(data[:model_id]).to eq('claude-opus-4-6')
      expect(data[:event_type]).to eq('llm_completion')
      expect(data[:status]).to eq('success')
    end

    it 'marks error responses as failure' do
      response = { error: 'something went wrong' }
      data = described_class.extract_metering_data(response, 'gpt-4o')
      expect(data[:status]).to eq('failure')
    end

    it 'handles non-hash responses' do
      data = described_class.extract_metering_data('raw string', 'gpt-4o')
      expect(data[:input_tokens]).to eq(0)
      expect(data[:output_tokens]).to eq(0)
      expect(data[:model_id]).to eq('gpt-4o')
    end

    it 'uses prompt_tokens and completion_tokens as fallbacks' do
      response = { usage: { prompt_tokens: 80, completion_tokens: 40 } }
      data = described_class.extract_metering_data(response, 'gpt-4o')
      expect(data[:input_tokens]).to eq(80)
      expect(data[:output_tokens]).to eq(40)
    end
  end

  describe '.metering_available?' do
    it 'returns false when nothing is available' do
      allow(described_class).to receive(:gateway_metering?).and_return(false)
      allow(described_class).to receive(:transport_metering?).and_return(false)
      expect(described_class.metering_available?).to be(false)
    end

    it 'returns true when gateway metering is available' do
      allow(described_class).to receive(:gateway_metering?).and_return(true)
      expect(described_class.metering_available?).to be(true)
    end

    it 'returns true when transport metering is available' do
      allow(described_class).to receive(:gateway_metering?).and_return(false)
      allow(described_class).to receive(:transport_metering?).and_return(true)
      expect(described_class.metering_available?).to be(true)
    end
  end

  describe '.record' do
    context 'when metering is unavailable' do
      before do
        allow(described_class).to receive(:metering_available?).and_return(false)
      end

      it 'does nothing' do
        expect(described_class).not_to receive(:publish_metering)
        described_class.record({ usage: { input_tokens: 100, output_tokens: 50 } }, 'gpt-4o')
      end
    end

    context 'when metering is available' do
      before do
        allow(described_class).to receive(:metering_available?).and_return(true)
        allow(described_class).to receive(:publish_metering)
      end

      it 'publishes metering data' do
        described_class.record({ usage: { input_tokens: 100, output_tokens: 50 } }, 'gpt-4o')
        expect(described_class).to have_received(:publish_metering).with(hash_including(input_tokens: 100))
      end

      it 'skips zero-token responses' do
        described_class.record({ usage: { input_tokens: 0, output_tokens: 0 } }, 'gpt-4o')
        expect(described_class).not_to have_received(:publish_metering)
      end
    end
  end
end
