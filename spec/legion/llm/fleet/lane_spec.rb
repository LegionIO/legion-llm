# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Fleet::Lane do
  describe '.routing_key' do
    it 'builds an embedding lane key' do
      expect(described_class.routing_key(operation: :embed, model: 'nomic-embed-text')).to eq(
        'llm.fleet.embed.nomic-embed-text'
      )
    end

    it 'builds an inference lane key with context bucket and boundary' do
      key = described_class.routing_key(
        operation:      :generation,
        model:          'qwen3.6:27b',
        context_window: 32_768,
        boundary:       :corp_lan
      )

      expect(key).to eq('llm.fleet.inference.qwen3-6-27b.ctx32768.boundary.corp-lan')
    end

    it 'adds an eligibility fingerprint when workers are not interchangeable' do
      key = described_class.routing_key(
        operation:               :chat,
        model:                   'qwen3.6:27b',
        context_window:          32_768,
        eligibility_fingerprint: 'abc123'
      )

      expect(key).to eq('llm.fleet.inference.qwen3-6-27b.ctx32768.elig.abc123')
    end

    it 'sanitizes repeated separators without regex backtracking' do
      key = described_class.routing_key(
        operation: :chat,
        model:     '---Qwen///3.6:::27B---',
        boundary:  '///corp---lan///'
      )

      expect(key).to eq('llm.fleet.inference.qwen-3-6-27b.boundary.corp-lan')
    end

    it 'rejects sensitive public route segments' do
      expect do
        described_class.routing_key(operation: :chat, model: 'qwen3.6:27b', boundary: 'bearer_token')
      end.to raise_error(ArgumentError, /boundary/)

      expect do
        described_class.routing_key(operation: :chat, model: 'qwen3.6:27b', eligibility_fingerprint: 'api_key_v2')
      end.to raise_error(ArgumentError, /eligibility_fingerprint/)
    end

    it 'rejects oversized public route segments' do
      expect do
        described_class.routing_key(operation: :chat, model: 'qwen3.6:27b', boundary: 'a' * 65)
      end.to raise_error(ArgumentError, /exceeds 64/)
    end
  end

  describe '.offering_key' do
    it 'builds an exact offering key' do
      expect(described_class.offering_key(instance_id: 'gpu-01', model: 'qwen3.6:27b', operation: :generation)).to eq(
        'llm.fleet.offering.gpu-01.qwen3-6-27b.inference'
      )
    end

    it 'rejects sensitive offering instance identifiers' do
      expect do
        described_class.offering_key(instance_id: 'client_secret', model: 'qwen3.6:27b', operation: :generation)
      end.to raise_error(ArgumentError, /instance_id/)
    end
  end

  describe '.eligibility_fingerprint' do
    it 'is stable for hash and array ordering differences' do
      first = described_class.eligibility_fingerprint(
        capabilities: %i[tools chat],
        boundary:     :corp_lan,
        operation:    :generation
      )
      second = described_class.eligibility_fingerprint(
        operation:    :generation,
        boundary:     :corp_lan,
        capabilities: %i[chat tools]
      )

      expect(first).to eq(second)
    end

    it 'rejects sensitive keys at any depth' do
      sensitive_values = {
        endpoint_url: 'http://gpu.internal',
        nested:       {
          Authorization: 'Bearer token',
          api_key_v2:    'abc123',
          x_api_key:     'def456',
          bearer_token:  'ghi789',
          client_secret: 'secret',
          refresh_token: 'refresh'
        }
      }

      expect do
        described_class.eligibility_fingerprint(capabilities: [:chat], **sensitive_values)
      end.to raise_error(
        ArgumentError,
        /endpoint_url|nested\.Authorization|nested\.api_key_v2|nested\.x_api_key|nested\.bearer_token|nested\.client_secret|nested\.refresh_token/
      )
    end
  end
end
