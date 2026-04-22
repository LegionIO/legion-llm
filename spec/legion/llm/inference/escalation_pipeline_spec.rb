# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm'
require 'legion/llm/quality/checker'
require 'legion/llm/router/escalation/chain'

RSpec.describe 'Pipeline escalation via step_provider_call' do
  let(:good_content) { 'This is a sufficiently long and varied response that passes all quality checks easily' }
  let(:short_content) { 'ok' }

  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :bedrock, model: 'claude-sonnet-4-6' }
    )
  end

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
        escalation:     {
          enabled:           true,
          pipeline_enabled:  true,
          max_attempts:      3,
          quality_threshold: 50
        },
        rules:          []
      }
    }
  end

  def build_mock_session(response)
    session = double('RubyLLM::Chat')
    allow(session).to receive(:with_tool).and_return(session)
    allow(session).to receive(:with_instructions).and_return(session)
    allow(session).to receive(:add_message).and_return(session)
    allow(session).to receive(:ask).and_return(response)
    session
  end

  def build_mock_response(content)
    double('RubyLLM::Message',
           content:            content,
           role:               'assistant',
           input_tokens:       10,
           output_tokens:      5,
           cache_read_tokens:  0,
           cache_write_tokens: 0,
           model_id:           'claude-sonnet-4-6')
  end

  describe 'when pipeline_enabled is false' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = false
    end

    it 'uses single provider call and returns a Inference::Response' do
      good_response = build_mock_response(good_content)
      session = build_mock_session(good_response)
      expect(RubyLLM).to receive(:chat).once.and_return(session)

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq(good_content)
    end

    it 'does not retry on quality failure' do
      short_response = build_mock_response(short_content)
      session = build_mock_session(short_response)
      expect(RubyLLM).to receive(:chat).once.and_return(session)

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result.message[:content]).to eq(short_content)
    end
  end

  describe 'when pipeline_enabled is true' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = true
    end

    it 'returns a Inference::Response on first passing attempt' do
      good_response = build_mock_response(good_content)
      session = build_mock_session(good_response)
      expect(RubyLLM).to receive(:chat).once.and_return(session)

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq(good_content)
    end

    it 'retries on quality failure and returns good response on second attempt' do
      short_response = build_mock_response(short_content)
      good_response  = build_mock_response(good_content)

      call_count = 0
      allow(RubyLLM).to receive(:chat) do
        call_count += 1
        if call_count == 1
          build_mock_session(short_response)
        else
          build_mock_session(good_response)
        end
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq(good_content)
      expect(call_count).to eq(2)
    end

    it 'retries on provider error and returns good response on second attempt' do
      good_response = build_mock_response(good_content)

      call_count = 0
      allow(RubyLLM).to receive(:chat) do
        call_count += 1
        session = double("Chat#{call_count}")
        allow(session).to receive(:with_tool).and_return(session)
        allow(session).to receive(:with_instructions).and_return(session)
        allow(session).to receive(:add_message).and_return(session)
        if call_count == 1
          allow(session).to receive(:ask).and_raise(StandardError, 'timeout')
        else
          allow(session).to receive(:ask).and_return(good_response)
        end
        session
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.message[:content]).to eq(good_content)
      expect(call_count).to eq(2)
    end

    it 'raises EscalationExhausted when all attempts fail' do
      call_count = 0
      allow(RubyLLM).to receive(:chat) do
        call_count += 1
        session = double("Chat#{call_count}")
        allow(session).to receive(:with_tool).and_return(session)
        allow(session).to receive(:with_instructions).and_return(session)
        allow(session).to receive(:add_message).and_return(session)
        allow(session).to receive(:ask).and_raise(StandardError, 'always fails')
        session
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      expect { executor.call }.to raise_error(Legion::LLM::EscalationExhausted)
    end

    it 'respects max_attempts setting' do
      Legion::Settings[:llm][:routing][:escalation][:max_attempts] = 2

      call_count = 0
      allow(RubyLLM).to receive(:chat) do
        call_count += 1
        session = double("Chat#{call_count}")
        allow(session).to receive(:with_tool).and_return(session)
        allow(session).to receive(:with_instructions).and_return(session)
        allow(session).to receive(:add_message).and_return(session)
        allow(session).to receive(:ask).and_raise(StandardError, 'fail')
        session
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      expect { executor.call }.to raise_error(Legion::LLM::EscalationExhausted)
      expect(call_count).to eq(2)
    end

    it 'records timeline events for each escalation attempt' do
      short_response = build_mock_response(short_content)
      good_response  = build_mock_response(good_content)

      call_count = 0
      allow(RubyLLM).to receive(:chat) do
        call_count += 1
        if call_count == 1
          build_mock_session(short_response)
        else
          build_mock_session(good_response)
        end
      end

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call

      escalation_events = result.timeline.select { |e| e[:key] == 'escalation:attempt' }
      expect(escalation_events.size).to eq(2)
    end

    it 'uses custom quality_check from request extra when present' do
      request_with_check = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { provider: :bedrock, model: 'claude-sonnet-4-6' },
        extra:    { quality_check: ->(r) { r.content.include?('SELECT') } }
      )

      bad_response  = build_mock_response('this response is long enough but lacks the keyword padding here')
      good_response = build_mock_response('SELECT * FROM users WHERE active = true and this is long enough')

      call_count = 0
      allow(RubyLLM).to receive(:chat) do
        call_count += 1
        if call_count == 1
          build_mock_session(bad_response)
        else
          build_mock_session(good_response)
        end
      end

      executor = Legion::LLM::Inference::Executor.new(request_with_check)
      result = executor.call
      expect(result.message[:content]).to include('SELECT')
    end

    it 'does not escalate when escalation settings are absent' do
      Legion::Settings[:llm][:routing] = {
        enabled:    false,
        rules:      [],
        escalation: { pipeline_enabled: false }
      }

      good_response = build_mock_response(good_content)
      session = build_mock_session(good_response)
      expect(RubyLLM).to receive(:chat).once.and_return(session)

      executor = Legion::LLM::Inference::Executor.new(request)
      result = executor.call
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end
end
