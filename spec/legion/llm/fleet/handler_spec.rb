# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Fleet::Handler do
  let(:messages) do
    [
      { role: 'system', content: 'be brief' },
      { role: 'user', content: 'real prompt' }
    ]
  end

  describe '.require_auth?' do
    it 'returns false by default' do
      expect(described_class.require_auth?).to eq(false)
    end

    it 'returns true when configured' do
      Legion::Settings[:llm][:routing] = { fleet: { require_auth: true } }
      expect(described_class.require_auth?).to eq(true)
    end
  end

  describe '.build_response' do
    it 'builds response hash from correlation_id and response object' do
      response = double(input_tokens: 10, output_tokens: 5, thinking_tokens: 0,
                        provider: :anthropic, model: 'claude-opus-4-6')
      result = described_class.build_response('corr-123', response)
      expect(result[:correlation_id]).to eq('corr-123')
      expect(result[:input_tokens]).to eq(10)
      expect(result[:output_tokens]).to eq(5)
      expect(result[:provider]).to eq(:anthropic)
    end

    it 'handles responses without token methods' do
      response = { content: 'hello' }
      result = described_class.build_response('corr-123', response)
      expect(result[:correlation_id]).to eq('corr-123')
      expect(result[:input_tokens]).to eq(0)
    end

    it 'preserves success, error, provider, and model from hash responses' do
      response = {
        success:  false,
        error:    'llm_not_available',
        provider: :openai,
        model:    'gpt-4o'
      }

      result = described_class.build_response('corr-123', response)

      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('llm_not_available')
      expect(result[:provider]).to eq(:openai)
      expect(result[:model_id]).to eq('gpt-4o')
    end
  end

  describe '.valid_token?' do
    it 'returns true when auth not required' do
      expect(described_class.valid_token?(nil)).to eq(true)
    end
  end

  describe '.handle_fleet_request' do
    it 'returns invalid_token when auth is required and the token is missing' do
      Legion::Settings[:llm][:routing] = { fleet: { require_auth: true } }

      result = described_class.handle_fleet_request(correlation_id: 'corr-123')

      expect(result).to eq(success: false, error: 'invalid_token')
    end

    it 'preserves unavailable-LLM failures from local execution' do
      allow(described_class).to receive(:call_local_llm).and_return(success: false, error: 'llm_not_available')

      result = described_class.handle_fleet_request(correlation_id: 'corr-123')

      expect(result[:success]).to eq(false)
      expect(result[:error]).to eq('llm_not_available')
      expect(result[:response]).to eq(success: false, error: 'llm_not_available')
    end
  end

  describe '.call_local_llm' do
    it 'forwards provider and model to structured execution' do
      expect(Legion::LLM).to receive(:structured_direct).with(
        messages: messages,
        schema:   { type: 'object' },
        model:    'claude-sonnet-4-6',
        provider: :anthropic
      )

      described_class.call_local_llm(
        request_type: 'structured',
        messages:     messages,
        schema:       { type: 'object' },
        model:        'claude-sonnet-4-6',
        provider:     :anthropic
      )
    end

    it 'forwards provider and model to embeddings execution' do
      expect(Legion::LLM).to receive(:embed_direct).with(
        'real prompt',
        model:    'text-embedding-3-small',
        provider: :openai
      )

      described_class.call_local_llm(
        request_type: 'embed',
        messages:     messages,
        model:        'text-embedding-3-small',
        provider:     :openai
      )
    end

    it 'replays prior messages before asking the final prompt' do
      session = instance_double('RubyLLM::Chat')
      allow(Legion::LLM).to receive(:send).with(
        :chat_single,
        model:    'claude-sonnet-4-6',
        provider: :anthropic,
        intent:   :support,
        tier:     :cloud,
        tools:    nil
      ).and_return(session)
      allow(session).to receive(:respond_to?).with(:with_instructions).and_return(true)
      allow(session).to receive(:with_instructions)
      allow(session).to receive(:add_message)
      allow(session).to receive(:ask).and_return({ content: 'done' })

      described_class.call_local_llm(
        request_type: 'chat',
        messages:     messages,
        model:        'claude-sonnet-4-6',
        provider:     :anthropic,
        intent:       :support,
        tier:         :cloud,
        system:       'follow system'
      )

      expect(session).to have_received(:with_instructions).with('follow system')
      expect(session).to have_received(:add_message).with(role: 'system', content: 'be brief')
      expect(session).to have_received(:ask).with('real prompt')
    end

    it 'returns llm_not_available when the request method is unavailable' do
      allow(Legion::LLM).to receive(:respond_to?).with(:chat_direct, true).and_return(false)

      result = described_class.call_local_llm(request_type: 'chat', messages: messages)

      expect(result).to eq(success: false, error: 'llm_not_available')
    end
  end
end
