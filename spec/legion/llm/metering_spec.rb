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
      stub_const('Legion::Transport', Module.new)
      allow(Legion::Transport).to receive(:connected?).and_return(true)
      msg_instance = instance_double(Legion::LLM::Metering::Event)
      allow(Legion::LLM::Metering::Event).to receive(:new).and_return(msg_instance)
      allow(msg_instance).to receive(:publish)

      expect(described_class.emit(event)).to eq(:published)
      expect(msg_instance).to have_received(:publish)
    end

    it 'returns :spooled when spool available and transport down' do
      stub_const('Legion::Data::Spool', Class.new)
      spool = double('spool')
      allow(Legion::Data::Spool).to receive(:for).and_return(spool)
      allow(spool).to receive(:write)

      expect(described_class.emit(event)).to eq(:spooled)
    end

    it 'never raises' do
      stub_const('Legion::Transport', Module.new)
      allow(Legion::Transport).to receive(:connected?).and_return(true)
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
end
