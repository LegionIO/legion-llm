# frozen_string_literal: true

require 'spec_helper'
require_relative '../../support/transport_stub'
require 'legion/llm/metering'

RSpec.describe Legion::LLM::Metering do
  let(:event) do
    { request_type: 'chat', provider: 'ollama', model_id: 'qwen3.5:27b', tier: 'fleet' }
  end

  describe '.emit' do
    it 'returns :dropped when transport not connected' do
      expect(described_class.emit(event)).to eq(:dropped)
    end

    it 'returns :published when transport is connected' do
      Legion::Settings[:transport][:connected] = true
      msg_instance = instance_double(Legion::LLM::Metering::Event)
      allow(Legion::LLM::Metering::Event).to receive(:new).and_return(msg_instance)
      allow(msg_instance).to receive(:publish)

      expect(described_class.emit(event)).to eq(:published)
      expect(msg_instance).to have_received(:publish)
    end

    it 'treats string-keyed transport settings as connected' do
      Legion::Settings[:transport]['connected'] = true
      msg_instance = instance_double(Legion::LLM::Metering::Event)
      allow(Legion::LLM::Metering::Event).to receive(:new).and_return(msg_instance)
      allow(msg_instance).to receive(:publish)

      expect(described_class.emit(event)).to eq(:published)
    end

    it 'returns :spooled when spool available and transport down' do
      stub_const('Legion::Data::Spool', Class.new)
      spool = double('spool')
      allow(Legion::Data::Spool).to receive(:for).and_return(spool)
      allow(spool).to receive(:count).and_return(0)
      allow(spool).to receive(:write)

      expect(described_class.emit(event)).to eq(:spooled)
    end

    it 'drops new metering events when the spool cap is reached' do
      stub_const('Legion::Data::Spool', Class.new)
      spool = double('spool')
      allow(Legion::Data::Spool).to receive(:for).and_return(spool)
      allow(spool).to receive(:count).with(:metering).and_return(1)
      allow(Legion::LLM::Settings).to receive(:value)
        .with(:metering, :spool, :max_events, default: described_class::DEFAULT_SPOOL_MAX)
        .and_return(1)

      expect(spool).not_to receive(:write)
      expect(described_class.emit(event)).to eq(:dropped)
    end

    it 'never raises' do
      Legion::Settings[:transport][:connected] = true
      allow(Legion::LLM::Metering::Event).to receive(:new).and_raise(StandardError, 'boom')

      expect { described_class.emit(event) }.not_to raise_error
      expect(described_class.emit(event)).to eq(:dropped)
    end
  end

  describe '.flush_spool' do
    it 'returns 0 when spool unavailable' do
      expect(described_class.flush_spool).to eq(0)
    end
  end

  describe '.extract_usage' do
    it 'reads OpenAI-style string-keyed usage payloads' do
      usage = described_class.extract_usage(
        'usage' => { 'prompt_tokens' => 10, 'completion_tokens' => 7 }
      )

      expect(usage).to eq(input_tokens: 10, output_tokens: 7)
    end
  end

  describe '.extract_provider and .extract_model' do
    it 'reads string-keyed metadata' do
      response = { 'meta' => { 'provider' => 'anthropic', 'model' => 'claude-sonnet-4-6' } }

      expect(described_class.extract_provider(response)).to eq('anthropic')
      expect(described_class.extract_model(response)).to eq('claude-sonnet-4-6')
    end
  end
end
