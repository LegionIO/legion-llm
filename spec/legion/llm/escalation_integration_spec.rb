# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm'
require 'legion/llm/quality_checker'
require 'legion/llm/escalation_history'
require 'legion/llm/router/escalation_chain'

RSpec.describe 'Legion::LLM.chat escalation' do
  let(:good_content) { 'This is a sufficiently long and varied response that passes all quality checks easily' }
  let(:short_content) { 'ok' }

  before do
    Legion::LLM::Router.reset!
    Legion::Settings[:llm] = {
      default_model:    'claude-sonnet-4-6',
      default_provider: :bedrock,
      providers:        { bedrock: { enabled: true, default_model: 'claude-sonnet-4-6' } },
      discovery:        { enabled: false },
      routing:          {
        enabled:        false,
        default_intent: {},
        escalation:     { enabled: true, max_attempts: 3, quality_threshold: 50 },
        rules:          []
      }
    }
  end

  describe 'with escalate: false' do
    it 'behaves like original chat (no retry, returns chat object)' do
      mock_chat = double('RubyLLM::Chat')
      expect(RubyLLM).to receive(:chat).once.and_return(mock_chat)
      result = Legion::LLM.chat(escalate: false)
      expect(result).to eq(mock_chat)
    end
  end

  describe 'with escalate: true and hard failure then success' do
    it 'retries on exception and returns successful response' do
      good_response = double('Response', content: good_content, role: :assistant)
      allow(good_response).to receive(:respond_to?).with(:extend).and_return(true)
      allow(good_response).to receive(:extend).with(Legion::LLM::EscalationHistory)
      allow(good_response).to receive(:record_escalation_attempt)
      allow(good_response).to receive(:final_resolution=)
      allow(good_response).to receive(:escalation_chain=)

      call_count = 0
      allow(RubyLLM).to receive(:chat) do
        call_count += 1
        chat = double("Chat#{call_count}")
        if call_count == 1
          allow(chat).to receive(:ask).and_raise(StandardError, 'API timeout')
        else
          allow(chat).to receive(:ask).and_return(good_response)
        end
        chat
      end

      response = Legion::LLM.chat(escalate: true, message: 'test')
      expect(response).to eq(good_response)
    end
  end

  describe 'with escalate: true and quality failure then success' do
    it 'retries on quality failure and returns good response' do
      bad_response = double('BadResponse', content: short_content, role: :assistant)
      good_response = double('GoodResponse', content: good_content, role: :assistant)
      allow(good_response).to receive(:respond_to?).with(:extend).and_return(true)
      allow(good_response).to receive(:extend).with(Legion::LLM::EscalationHistory)
      allow(good_response).to receive(:record_escalation_attempt)
      allow(good_response).to receive(:final_resolution=)
      allow(good_response).to receive(:escalation_chain=)

      call_count = 0
      allow(RubyLLM).to receive(:chat) do
        call_count += 1
        chat = double("Chat#{call_count}")
        if call_count == 1
          allow(chat).to receive(:ask).and_return(bad_response)
        else
          allow(chat).to receive(:ask).and_return(good_response)
        end
        chat
      end

      response = Legion::LLM.chat(escalate: true, message: 'test')
      expect(response).to eq(good_response)
    end
  end

  describe 'with escalate: true and all failures' do
    it 'raises EscalationExhausted after exhausting chain' do
      allow(RubyLLM).to receive(:chat) do
        chat = double('Chat')
        allow(chat).to receive(:ask).and_raise(StandardError, 'fail')
        chat
      end

      expect do
        Legion::LLM.chat(escalate: true, message: 'test')
      end.to raise_error(Legion::LLM::EscalationExhausted)
    end
  end

  describe 'with custom quality_check' do
    it 'uses custom check for quality assessment' do
      call_count = 0
      allow(RubyLLM).to receive(:chat) do
        call_count += 1
        chat = double("Chat#{call_count}")
        if call_count == 1
          resp = double('BadResp', content: 'no sql here but long enough to pass basic checks yeah', role: :assistant)
          allow(chat).to receive(:ask).and_return(resp)
        else
          good = double('GoodResp', content: 'SELECT * FROM users WHERE active = true padding text here', role: :assistant)
          allow(good).to receive(:respond_to?).with(:extend).and_return(true)
          allow(good).to receive(:extend).with(Legion::LLM::EscalationHistory)
          allow(good).to receive(:record_escalation_attempt)
          allow(good).to receive(:final_resolution=)
          allow(good).to receive(:escalation_chain=)
          allow(chat).to receive(:ask).and_return(good)
        end
        chat
      end

      custom = ->(r) { r.content.include?('SELECT') }
      response = Legion::LLM.chat(escalate: true, message: 'test', quality_check: custom)
      expect(response.content).to include('SELECT')
    end
  end

  describe 'without escalation enabled' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:enabled] = false
    end

    it 'defaults escalate to false and returns chat object' do
      mock_chat = double('RubyLLM::Chat')
      expect(RubyLLM).to receive(:chat).once.and_return(mock_chat)
      result = Legion::LLM.chat
      expect(result).to eq(mock_chat)
    end
  end
end
