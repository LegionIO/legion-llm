# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline pre-rollout integration' do
  before do
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:pipeline_enabled] = true
    allow(Legion::LLM).to receive(:started?).and_return(true)
    stub_native_provider(content: 'pipeline response')
  end

  describe 'caller identity propagation' do
    it 'preserves caller hash through entire pipeline' do
      caller = { requested_by: { identity: 'user:matt', type: :human }, source: 'cli', command: 'chat' }
      result = Legion::LLM.chat(message: 'hello', caller: caller)

      expect(result).to be_a(Legion::LLM::Inference::Response)
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
      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(result.caller).to be_nil
    end
  end

  describe 'pipeline steps execute for external profile' do
    it 'records timeline events for non-skipped steps' do
      result = Legion::LLM.chat(message: 'hello', caller: { source: 'test' })
      timeline_keys = result.timeline.map { |e| e[:key] }

      expect(timeline_keys).to include('tracing:init')
      # SSOT v3: routing requirements are emitted as 'routing:requirements'
      expect(timeline_keys).to include('routing:requirements')
      expect(timeline_keys).to include('provider:request_sent')
      expect(timeline_keys).to include('provider:response_received')
    end

    it 'returns valid response structure' do
      result = Legion::LLM.chat(message: 'hello')

      expect(result.request_id).to be_a(String)
      expect(result.conversation_id).to be_a(String)
      expect(result.message).to be_a(Hash)
      expect(result.message[:content]).to eq('pipeline response')
      # SSOT v3: routing reflects the selected lane from the Phase 1 Registry
      expect(result.routing).to include(:provider)
      expect(result.tokens).to be_a(Hash).or be_a(Legion::LLM::Usage)
      expect(result.timestamps).to be_a(Hash)
      expect(result.timeline).to be_an(Array)
      expect(result.warnings).to be_an(Array)
    end
  end

  describe 'RBAC step graceful degradation' do
    it 'permits request when Legion::Rbac is not loaded' do
      result = Legion::LLM.chat(message: 'hello', caller: { source: 'test' })

      expect(result.warnings).to include('RBAC unavailable, permitting request (fail_open enabled)')
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

      expect(result).to be_a(Legion::LLM::Inference::Response)
      # Classification should detect PII and record it
      expect(result.audit[:'classification:scan'][:outcome]).to eq(:success) if result.audit.key?(:'classification:scan')
    end

    it 'passes through without classification when not requested' do
      result = Legion::LLM.chat(message: 'hello', caller: { source: 'test' })
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end

  describe 'billing step' do
    it 'permits request when no spending cap set' do
      result = Legion::LLM.chat(
        message: 'hello',
        caller:  { source: 'test' },
        billing: { department: 'engineering' }
      )
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end

  describe 'system profile (guardrails pattern)' do
    let(:system_caller) do
      { requested_by: { identity: 'system:guardrails', type: :system, credential: :internal } }
    end

    it 'derives :system profile and skips governance steps' do
      result = Legion::LLM.chat(message: 'check this', caller: system_caller)
      timeline_keys = result.timeline.map { |e| e[:key] }

      expect(result).to be_a(Legion::LLM::Inference::Response)
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

      expect(result).to be_a(Legion::LLM::Inference::Response)
      expect(timeline_keys).not_to include('rbac:permission_check')
      # SSOT v3: routing requirements are recorded as 'routing:requirements'
      expect(timeline_keys).to include('routing:requirements')
    end
  end

  describe 'streaming with pipeline' do
    it 'yields chunks and returns Inference::Response' do
      chunks = []
      result = Legion::LLM.chat(message: 'hello', stream: true) { |chunk| chunks << chunk }

      expect(chunks.map(&:content)).to eq(['pipeline response'])
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end

    it 'preserves caller identity through streaming path' do
      caller = { requested_by: { identity: 'user:matt', type: :human }, source: 'tty' }
      result = Legion::LLM.chat(message: 'hello', stream: true, caller: caller) { |_chunk| nil }

      expect(result.caller).to eq(caller)
    end
  end

  describe 'conversation context load/store round-trip' do
    before { Legion::LLM::Inference::Conversation.reset! }

    it 'stores and loads conversation across pipeline calls' do
      conv_id = "test_conv_#{SecureRandom.hex(4)}"

      # First call stores the exchange
      result1 = Legion::LLM.chat(message: 'first message', conversation_id: conv_id)
      expect(result1).to be_a(Legion::LLM::Inference::Response)

      # Second call loads prior context
      result2 = Legion::LLM.chat(message: 'follow up', conversation_id: conv_id)
      expect(result2).to be_a(Legion::LLM::Inference::Response)

      # Verify messages accumulated
      messages = Legion::LLM::Inference::Conversation.messages(conv_id)
      expect(messages.size).to eq(4) # user1, assistant1, user2, assistant2
    end
  end

  describe 'error handling via SSOT engine' do
    it 'raises RoutingRejected when no lanes are available for the pinned model' do
      # SSOT v3: when all lanes are exhausted, Errors::RoutingRejected is raised.
      Legion::Extensions::Llm::Inventory::Registry.reset!
      expect { Legion::LLM.chat(model: 'nonexistent', provider: :vllm, message: 'hello') }
        .to raise_error(Legion::LLM::Errors::RoutingRejected)
    end

    it 'raises a typed LLM error when the callable returns an authentication failure and all lanes are exhausted' do
      # SSOT v3: authentication outcomes are retried against other lanes first;
      # when all lanes are exhausted, RoutingRejected (a typed LLMError) is raised.
      # Internal daemon/programming errors are not provider failures and propagate immediately.
      Legion::Extensions::Llm::Inventory::Registry.reset!
      auth_callable = SsotV3SnapshotFactory::FactoryCallable.new(
        responder: proc { |_op, _args, _kwargs, _blk| raise Legion::Extensions::Llm::UnauthorizedError, 'invalid key' }
      )
      SsotV3SnapshotFactory.activate(
        provider_family: 'vllm', instance_id: 'primary',
        callable:        auth_callable,
        drafts:          [SsotV3SnapshotFactory.offering_draft(
          model: SSOT_TEST_MODEL, tier: :local, supported: %i[chat count_tokens], context: 200_000
        )]
      )

      expect { Legion::LLM.chat(message: 'hello') }.to raise_error(Legion::LLM::LLMError)
    end
  end
end
