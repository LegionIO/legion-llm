# frozen_string_literal: true

require 'spec_helper'
require_relative '../../support/transport_stub'
require 'legion/llm/hooks'
require 'legion/llm/metering'
require 'tmpdir'

RSpec.describe Legion::LLM::Metering do
  let(:event) do
    { request_type: 'chat', provider: 'ollama', model_id: 'qwen3.5:27b', tier: 'fleet' }
  end

  let(:tmp_spool_dir) { Dir.mktmpdir('metering_spool') }
  let(:tmp_spool_file) { File.join(tmp_spool_dir, 'events.jsonl') }

  before do
    stub_const('Legion::LLM::Metering::SPOOL_DIR', tmp_spool_dir)
    stub_const('Legion::LLM::Metering::SPOOL_FILE', tmp_spool_file)
  end

  after do
    FileUtils.rm_rf(tmp_spool_dir)
  end

  describe '.emit' do
    it 'returns :spooled when transport not connected' do
      expect(described_class.emit(event)).to eq(:spooled)
    end

    it 'writes event to spool file when transport not connected' do
      described_class.emit(event)

      expect(File.exist?(tmp_spool_file)).to be true
      lines = File.readlines(tmp_spool_file, chomp: true)
      expect(lines.size).to eq(1)
      parsed = Legion::JSON.load(lines.first)
      expect(parsed[:provider]).to eq('ollama')
      expect(parsed[:model_id]).to eq('qwen3.5:27b')
    end

    it 'returns :published when transport is connected' do
      Legion::Settings[:transport][:connected] = true
      msg_instance = instance_double(Legion::LLM::Metering::Event)
      allow(Legion::LLM::Metering::Event).to receive(:new).and_return(msg_instance)
      allow(msg_instance).to receive(:publish)

      expect(described_class.emit(event)).to eq(:published)
      expect(msg_instance).to have_received(:publish)
    end

    it 'treats symbol-keyed transport settings as connected' do
      Legion::Settings[:transport][:connected] = true
      msg_instance = instance_double(Legion::LLM::Metering::Event)
      allow(Legion::LLM::Metering::Event).to receive(:new).and_return(msg_instance)
      allow(msg_instance).to receive(:publish)

      expect(described_class.emit(event)).to eq(:published)
    end

    it 'spools when transport is unavailable even if a data spool exists' do
      stub_const('Legion::Data::Spool', Class.new)
      allow(Legion::Data::Spool).to receive(:for)

      expect(described_class.emit(event)).to eq(:spooled)
      expect(Legion::Data::Spool).not_to have_received(:for)
    end

    it 'does not write metering events to a Legion::Data::Spool' do
      stub_const('Legion::Data::Spool', Class.new)
      spool = double('spool', count: 0)
      allow(Legion::Data::Spool).to receive(:for).and_return(spool)
      allow(spool).to receive(:write)

      expect(spool).not_to receive(:write)
      described_class.emit(event)
    end

    it 'never raises' do
      Legion::Settings[:transport][:connected] = true
      allow(Legion::LLM::Metering::Event).to receive(:new).and_raise(StandardError, 'boom')

      expect { described_class.emit(event) }.not_to raise_error
      expect(described_class.emit(event)).to eq(:dropped)
    end

    it 'enforces max_events by dropping oldest' do
      Legion::Settings[:llm][:metering][:spool][:max_events] = 3

      5.times { |i| described_class.emit(event.merge(model_id: "model_#{i}")) }

      lines = File.readlines(tmp_spool_file, chomp: true)
      expect(lines.size).to eq(3)
      # Newest events should remain
      parsed_last = Legion::JSON.load(lines.last)
      expect(parsed_last[:model_id]).to eq('model_4')
    end

    it 'is thread-safe under concurrent writes' do
      threads = 10.times.map do |i|
        Thread.new { described_class.emit(event.merge(model_id: "thread_#{i}")) }
      end
      threads.each(&:join)

      lines = File.readlines(tmp_spool_file, chomp: true)
      expect(lines.size).to eq(10)
    end
  end

  describe '.flush_spool' do
    it 'returns 0 when spool file does not exist' do
      expect(described_class.flush_spool).to eq(0)
    end

    it 'returns 0 when transport is unavailable' do
      described_class.emit(event)
      expect(File.exist?(tmp_spool_file)).to be true

      expect(described_class.flush_spool).to eq(0)
    end

    it 'publishes spooled events and returns count when transport reconnects' do
      # Spool some events while transport is down
      3.times { described_class.emit(event) }
      expect(File.readlines(tmp_spool_file, chomp: true).size).to eq(3)

      # Reconnect transport
      Legion::Settings[:transport][:connected] = true
      msg_instance = instance_double(Legion::LLM::Metering::Event)
      allow(Legion::LLM::Metering::Event).to receive(:new).and_return(msg_instance)
      allow(msg_instance).to receive(:publish)

      flushed = described_class.flush_spool
      expect(flushed).to eq(3)
      expect(msg_instance).to have_received(:publish).exactly(3).times
    end

    it 'truncates spool file after successful flush' do
      described_class.emit(event)
      expect(File.readlines(tmp_spool_file, chomp: true).size).to eq(1)

      Legion::Settings[:transport][:connected] = true
      msg_instance = instance_double(Legion::LLM::Metering::Event)
      allow(Legion::LLM::Metering::Event).to receive(:new).and_return(msg_instance)
      allow(msg_instance).to receive(:publish)

      described_class.flush_spool

      expect(File.read(tmp_spool_file)).to eq('')
    end

    it 'returns 0 on error without raising' do
      # Create a corrupt spool file
      File.write(tmp_spool_file, "not valid json\n")
      Legion::Settings[:transport][:connected] = true
      msg_instance = instance_double(Legion::LLM::Metering::Event)
      allow(Legion::LLM::Metering::Event).to receive(:new).and_return(msg_instance)
      allow(msg_instance).to receive(:publish).and_raise(StandardError, 'publish failed')

      expect { described_class.flush_spool }.not_to raise_error
      expect(described_class.flush_spool).to eq(0)
    end
  end

  describe '.install_hook' do
    after do
      Legion::LLM::Hooks.reset!
    end

    it 'forwards after_chat caller context into emitted metering events' do
      allow(described_class).to receive(:emit)

      described_class.install_hook
      Legion::LLM::Hooks.run_after(
        response: { usage: { input_tokens: 12, output_tokens: 4 }, meta: { provider: 'ollama', model: 'qwen' } },
        messages: [{ role: 'user', content: 'hello' }],
        model:    'qwen',
        caller:   { requested_by: { identity: 'user:alice', type: :human } }
      )

      expect(described_class).to have_received(:emit).with(hash_including(
                                                             caller: { requested_by: { identity: 'user:alice',
                                                                                       type:     :human } }
                                                           ))
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
