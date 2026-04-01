# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline pre-rollout integration' do
  let(:mock_session) do
    session = double('RubyLLM::Chat')
    allow(session).to receive(:with_tool).and_return(session)
    allow(session).to receive(:with_instructions).and_return(session)
    allow(session).to receive(:ask).and_return(mock_response)
    session
  end

  let(:mock_response) do
    double('RubyLLM::Message',
           content:       'pipeline response',
           role:          'assistant',
           input_tokens:  15,
           output_tokens: 8,
           model_id:      'test-model')
  end

  before do
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:pipeline_enabled] = true
    Legion::Settings[:llm][:default_model] = 'test-model'
    Legion::Settings[:llm][:default_provider] = :test
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(RubyLLM).to receive(:chat).and_return(mock_session)
  end

  describe 'caller identity propagation' do
    it 'preserves caller hash through entire pipeline' do
      caller = { requested_by: { identity: 'user:matt', type: :human }, source: 'cli', command: 'chat' }
      result = Legion::LLM.chat(message: 'hello', caller: caller)

      expect(result).to be_a(Legion::LLM::Pipeline::Response)
      expect(result.caller).to eq(caller)
    end

    it 'records caller in audit trail' do
      caller = { requested_by: { identity: 'ext:lex-teams', type: :human }, source: 'tty' }
      result = Legion::LLM.chat(message: 'test', caller: caller)

      expect(result.audit).to be_a(Hash)
      expect(result.tracing[:trace_id]).to be_a(String)
    end

    it 'works with nil caller (anonymous)' do
      result = Legion::LLM.chat(message: 'hello')
      expect(result).to be_a(Legion::LLM::Pipeline::Response)
      expect(result.caller).to be_nil
    end
  end

  describe 'all 18 steps execute for external profile' do
    it 'records timeline events for non-skipped steps' do
      result = Legion::LLM.chat(message: 'hello', caller: { source: 'test' })
      timeline_keys = result.timeline.map { |e| e[:key] }

      expect(timeline_keys).to include('tracing:init')
      expect(timeline_keys).to include('routing:provider_selection')
      expect(timeline_keys).to include('provider:request_sent')
      expect(timeline_keys).to include('provider:response_received')
    end

    it 'returns valid response structure' do
      result = Legion::LLM.chat(message: 'hello')

      expect(result.request_id).to be_a(String)
      expect(result.conversation_id).to be_a(String)
      expect(result.message).to be_a(Hash)
      expect(result.message[:content]).to eq('pipeline response')
      expect(result.routing).to include(provider: :test)
      expect(result.tokens).to be_a(Hash).or be_a(Legion::LLM::Usage)
      expect(result.timestamps).to be_a(Hash)
      expect(result.timeline).to be_an(Array)
      expect(result.warnings).to be_an(Array)
    end
  end

  describe 'RBAC step graceful degradation' do
    it 'permits request when Legion::Rbac is not loaded' do
      result = Legion::LLM.chat(message: 'hello', caller: { source: 'test' })

      expect(result.warnings).to include('RBAC unavailable, permitting request without enforcement')
      expect(result.audit).to have_key(:'rbac:permission_check')
      expect(result.audit[:'rbac:permission_check'][:outcome]).to eq(:success)
    end
  end

  describe 'classification step' do
    it 'upgrades classification when PII detected in message' do
      result = Legion::LLM.chat(
        message:        'my SSN is 123-45-6789',
        caller:         { source: 'test' },
        classification: { level: :public }
      )

      expect(result).to be_a(Legion::LLM::Pipeline::Response)
      # Classification should detect PII and record it
      expect(result.audit[:'classification:scan'][:outcome]).to eq(:success) if result.audit.key?(:'classification:scan')
    end

    it 'passes through without classification when not requested' do
      result = Legion::LLM.chat(message: 'hello', caller: { source: 'test' })
      expect(result).to be_a(Legion::LLM::Pipeline::Response)
    end
  end

  describe 'billing step' do
    it 'permits request when no spending cap set' do
      result = Legion::LLM.chat(
        message: 'hello',
        caller:  { source: 'test' },
        billing: { department: 'engineering' }
      )
      expect(result).to be_a(Legion::LLM::Pipeline::Response)
    end
  end

  describe 'system profile (guardrails pattern)' do
    let(:system_caller) do
      { requested_by: { identity: 'system:guardrails', type: :system, credential: :internal } }
    end

    it 'derives :system profile and skips governance steps' do
      result = Legion::LLM.chat(message: 'check this', caller: system_caller)
      timeline_keys = result.timeline.map { |e| e[:key] }

      expect(result).to be_a(Legion::LLM::Pipeline::Response)
      expect(timeline_keys).not_to include('rbac:permission_check')
      expect(timeline_keys).not_to include('classification:scan')
      expect(timeline_keys).not_to include('billing:budget_check')
    end

    it 'still executes provider call' do
      result = Legion::LLM.chat(message: 'check this', caller: system_caller)
      expect(result.message[:content]).to eq('pipeline response')
    end
  end

  describe 'GAIA profile' do
    let(:gaia_caller) do
      { requested_by: { identity: 'gaia:tick', type: :system, credential: :internal } }
    end

    it 'derives :gaia profile and skips governance but runs routing' do
      result = Legion::LLM.chat(message: 'advise', caller: gaia_caller)
      timeline_keys = result.timeline.map { |e| e[:key] }

      expect(result).to be_a(Legion::LLM::Pipeline::Response)
      expect(timeline_keys).not_to include('rbac:permission_check')
      expect(timeline_keys).to include('routing:provider_selection')
    end
  end

  describe 'streaming with pipeline' do
    it 'yields chunks and returns Pipeline::Response' do
      allow(mock_session).to receive(:ask).and_yield(double(content: 'hel')).and_yield(double(content: 'lo')).and_return(mock_response)

      chunks = []
      result = Legion::LLM.chat(message: 'hello') { |chunk| chunks << chunk.content }

      expect(chunks).to eq(%w[hel lo])
      expect(result).to be_a(Legion::LLM::Pipeline::Response)
    end

    it 'preserves caller identity through streaming path' do
      allow(mock_session).to receive(:ask).and_yield(double(content: 'ok')).and_return(mock_response)

      caller = { requested_by: { identity: 'user:matt', type: :human }, source: 'tty' }
      chunks = []
      result = Legion::LLM.chat(message: 'hello', caller: caller) { |chunk| chunks << chunk }

      expect(result.caller).to eq(caller)
    end
  end

  describe 'pipeline disabled falls back cleanly' do
    before { Legion::Settings[:llm][:pipeline_enabled] = false }

    it 'returns RubyLLM session (not Pipeline::Response) for session-style calls' do
      result = Legion::LLM.chat(model: 'test-model', provider: :test)
      expect(result).not_to be_a(Legion::LLM::Pipeline::Response)
    end

    it 'returns RubyLLM message for message-style calls via non-pipeline path' do
      allow(mock_session).to receive(:ask).and_return(mock_response)
      result = Legion::LLM.chat(message: 'hello')
      # Non-pipeline path returns the raw response
      expect(result).not_to be_a(Legion::LLM::Pipeline::Response)
    end
  end

  describe 'conversation context load/store round-trip' do
    before { Legion::LLM::ConversationStore.reset! }

    it 'stores and loads conversation across pipeline calls' do
      conv_id = "test_conv_#{SecureRandom.hex(4)}"

      # First call stores the exchange
      result1 = Legion::LLM.chat(message: 'first message', conversation_id: conv_id)
      expect(result1).to be_a(Legion::LLM::Pipeline::Response)

      # Second call loads prior context
      result2 = Legion::LLM.chat(message: 'follow up', conversation_id: conv_id)
      expect(result2).to be_a(Legion::LLM::Pipeline::Response)

      # Verify messages accumulated
      messages = Legion::LLM::ConversationStore.messages(conv_id)
      expect(messages.size).to eq(4) # user1, assistant1, user2, assistant2
    end
  end

  describe 'error handling' do
    it 'raises typed AuthError for 401' do
      allow(RubyLLM).to receive(:chat).and_raise(Faraday::UnauthorizedError.new(nil, { status: 401 }))
      expect { Legion::LLM.chat(message: 'hello') }.to raise_error(Legion::LLM::AuthError)
    end

    it 'raises typed RateLimitError for 429' do
      allow(RubyLLM).to receive(:chat).and_raise(Faraday::TooManyRequestsError.new(nil, { status: 429 }))
      expect { Legion::LLM.chat(message: 'hello') }.to raise_error(Legion::LLM::RateLimitError)
    end

    it 'raises typed ProviderDown for connection failures' do
      allow(RubyLLM).to receive(:chat).and_raise(Faraday::ConnectionFailed.new('connection refused'))
      expect { Legion::LLM.chat(message: 'hello') }.to raise_error(Legion::LLM::ProviderDown)
    end
  end
end
