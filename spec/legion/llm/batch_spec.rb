# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/scheduling/batch'

RSpec.describe Legion::LLM::Scheduling::Batch do
  before do
    described_class.reset!
    Legion::Settings[:llm][:batch] = { enabled: true, window_seconds: 0, max_batch_size: 100 }
    allow(Legion::LLM).to receive(:chat_direct).and_return({ content: 'test response' })
  end

  after do
    described_class.reset!
  end

  describe '.enabled?' do
    it 'returns false by default (before settings override)' do
      Legion::Settings[:llm][:batch] = {}
      expect(described_class.enabled?).to be false
    end

    it 'returns true when enabled in settings' do
      Legion::Settings[:llm][:batch] = { enabled: true }
      expect(described_class.enabled?).to be true
    end

    it 'returns false when explicitly disabled' do
      Legion::Settings[:llm][:batch] = { enabled: false }
      expect(described_class.enabled?).to be false
    end
  end

  describe '.enqueue' do
    it 'returns a string UUID' do
      id = described_class.enqueue(messages: [{ role: 'user', content: 'hello' }], model: 'gpt-4o')
      expect(id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it 'increments the queue size' do
      expect do
        described_class.enqueue(messages: [{ role: 'user', content: 'hi' }], model: 'gpt-4o')
      end.to change(described_class, :queue_size).by(1)
    end

    it 'stores the model and messages' do
      described_class.enqueue(
        messages: [{ role: 'user', content: 'test' }],
        model:    'claude-sonnet-4-6',
        provider: :anthropic
      )
      expect(described_class.queue_size).to eq(1)
    end

    it 'accepts an optional callback proc' do
      called = false
      cb = proc { |_result| called = true }
      described_class.enqueue(
        messages: [{ role: 'user', content: 'hi' }],
        model:    'gpt-4o',
        callback: cb
      )
      expect(described_class.queue_size).to eq(1)
      # Callback not yet invoked — just stored
      expect(called).to be false
    end

    it 'accepts priority option without error' do
      expect do
        described_class.enqueue(
          messages: [{ role: 'user', content: 'low' }],
          model:    'gpt-4o',
          priority: :low
        )
      end.not_to raise_error
    end
  end

  describe '.flush' do
    context 'when queue is empty' do
      it 'returns an empty array' do
        expect(described_class.flush).to eq([])
      end
    end

    context 'with window_seconds: 0 (flush all)' do
      it 'flushes all enqueued requests' do
        described_class.enqueue(messages: [{ role: 'user', content: 'a' }], model: 'gpt-4o')
        described_class.enqueue(messages: [{ role: 'user', content: 'b' }], model: 'gpt-4o')

        results = described_class.flush
        expect(results.size).to eq(2)
        expect(described_class.queue_size).to eq(0)
      end

      it 'returns result hashes with expected keys' do
        described_class.enqueue(messages: [{ role: 'user', content: 'test' }], model: 'gpt-4o')
        results = described_class.flush
        result = results.first
        expect(result).to include(:id, :status, :result)
        expect(result[:status]).to eq(:completed)
      end

      it 'invokes callbacks with the result' do
        received = nil
        cb = proc { |r| received = r }
        described_class.enqueue(
          messages: [{ role: 'user', content: 'hi' }],
          model:    'gpt-4o',
          callback: cb
        )
        described_class.flush
        expect(received).to be_a(Hash)
        expect(received[:status]).to eq(:completed)
      end

      it 'groups requests by provider and model' do
        described_class.enqueue(
          messages: [{ role: 'user', content: 'a' }], model: 'gpt-4o', provider: :openai
        )
        described_class.enqueue(
          messages: [{ role: 'user', content: 'b' }], model: 'gpt-4o', provider: :openai
        )
        described_class.enqueue(
          messages: [{ role: 'user', content: 'c' }], model: 'claude-sonnet-4-6', provider: :anthropic
        )

        results = described_class.flush
        expect(results.size).to eq(3)
        models = results.map { |r| r[:result][:model] }
        expect(models).to include('gpt-4o', 'claude-sonnet-4-6')
      end

      it 'respects max_size limit' do
        5.times { |i| described_class.enqueue(messages: [{ role: 'user', content: i.to_s }], model: 'gpt-4o') }

        results = described_class.flush(max_size: 3)
        expect(results.size).to eq(3)
        expect(described_class.queue_size).to eq(2)
      end
    end

    context 'with window_seconds > 0 (time-gated flush)' do
      it 'does not flush recently enqueued requests' do
        Legion::Settings[:llm][:batch] = { enabled: true, window_seconds: 300, max_batch_size: 100 }
        described_class.enqueue(messages: [{ role: 'user', content: 'new' }], model: 'gpt-4o')

        results = described_class.flush(max_wait: 300)
        expect(results).to be_empty
        expect(described_class.queue_size).to eq(1)
      end
    end

    context 'with the real chat_direct path' do
      let(:session) { double('session') }
      let(:response) { double('response', content: 'batched response') }

      before do
        allow(Legion::LLM).to receive(:chat_direct).and_call_original
        Legion::Settings[:llm][:scheduling] = {
          enabled:         true,
          peak_hours_utc:  '0-23',
          defer_intents:   %w[batch background],
          max_defer_hours: 8
        }
        allow(RubyLLM).to receive(:chat).and_return(session)
        allow(session).to receive(:ask).and_return(response)
      end

      it 'executes the queued request and preserves provider and model' do
        described_class.enqueue(
          messages: [{ role: 'user', content: 'batched hello' }],
          model:    'gpt-4o',
          provider: :openai
        )

        results = described_class.flush

        expect(RubyLLM).to have_received(:chat).with(hash_including(model: 'gpt-4o', provider: :openai))
        expect(session).to have_received(:ask).with('batched hello')
        expect(results.first[:status]).to eq(:completed)
        expect(results.first[:result][:response]).to eq(response)
      end
    end
  end

  describe '.queue_size' do
    it 'starts at 0 after reset' do
      expect(described_class.queue_size).to eq(0)
    end

    it 'reflects enqueued items' do
      3.times { described_class.enqueue(messages: [{ role: 'user', content: 'x' }], model: 'gpt-4o') }
      expect(described_class.queue_size).to eq(3)
    end
  end

  describe '.status' do
    it 'returns hash with queue state' do
      s = described_class.status
      expect(s[:queue_size]).to eq(0)
      expect(s).to have_key(:enabled)
      expect(s).to have_key(:max_batch_size)
      expect(s).to have_key(:window_seconds)
    end

    it 'reflects enqueued items and priorities' do
      described_class.enqueue(messages: [{ role: 'user', content: 'a' }], model: 'gpt-4o', priority: :normal)
      described_class.enqueue(messages: [{ role: 'user', content: 'b' }], model: 'gpt-4o', priority: :low)
      s = described_class.status
      expect(s[:queue_size]).to eq(2)
      expect(s[:by_priority][:normal]).to eq(1)
      expect(s[:by_priority][:low]).to eq(1)
      expect(s[:oldest_queued]).to be_a(String)
    end
  end

  describe '.reset!' do
    it 'clears the queue' do
      described_class.enqueue(messages: [{ role: 'user', content: 'hi' }], model: 'gpt-4o')
      described_class.reset!
      expect(described_class.queue_size).to eq(0)
    end
  end
end
