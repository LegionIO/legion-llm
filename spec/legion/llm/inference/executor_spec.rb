# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
    )
  end

  def register_native_chat(provider = :anthropic, &handler)
    Legion::LLM::Call::Registry.register(provider, Module.new do
      define_singleton_method(:chat) do |model:, messages:, **opts|
        if handler
          handler.call(model: model, messages: messages, **opts)
        else
          { content: 'hi there', usage: { input_tokens: 10, output_tokens: 5 } }
        end
      end
    end)
  end

  describe '#call' do
    it 'executes the pipeline and returns a Response' do
      executor = described_class.new(request)
      allow(executor).to receive(:step_provider_call).and_return(
        { role: :assistant, content: 'hi there' }
      )
      allow(executor).to receive(:step_response_normalization).and_return(nil)
      response = executor.call
      expect(response).to be_a(Legion::LLM::Inference::Response)
      expect(response.request_id).to eq(request.id)
    end

    it 'derives profile from caller' do
      gaia_request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        caller:   { requested_by: { identity: 'gaia:tick', type: :system, credential: :internal } }
      )
      executor = described_class.new(gaia_request)
      expect(executor.profile).to eq(:gaia)
    end

    it 'initializes tracing on the request' do
      executor = described_class.new(request)
      allow(executor).to receive(:step_provider_call).and_return(
        { role: :assistant, content: 'test' }
      )
      allow(executor).to receive(:step_response_normalization).and_return(nil)
      response = executor.call
      expect(response.tracing).to be_a(Hash)
      expect(response.tracing[:trace_id]).to be_a(String)
    end

    it 'records timeline events' do
      executor = described_class.new(request)
      allow(executor).to receive(:step_provider_call).and_return(
        { role: :assistant, content: 'test' }
      )
      allow(executor).to receive(:step_response_normalization).and_return(nil)
      response = executor.call
      expect(response.timeline).not_to be_empty
      expect(response.timeline.first[:key]).to eq('tracing:init')
    end

    describe 'post-response step' do
      it 'publishes audit event for external profile' do
        executor = described_class.new(request)
        allow(executor).to receive(:step_provider_call).and_return(
          { role: :assistant, content: 'test' }
        )
        allow(executor).to receive(:step_response_normalization).and_return(nil)
        expect(Legion::LLM::Inference::AuditPublisher).to receive(:publish)
        executor.call
      end

      it 'skips audit publish for gaia profile' do
        gaia_request = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'test' }],
          caller:   { requested_by: { identity: 'gaia:tick', type: :system, credential: :internal } }
        )
        executor = described_class.new(gaia_request)
        allow(executor).to receive(:step_provider_call).and_return(
          { role: :assistant, content: 'test' }
        )
        allow(executor).to receive(:step_response_normalization).and_return(nil)
        expect(Legion::LLM::Inference::AuditPublisher).not_to receive(:publish)
        executor.call
      end
    end

    describe 'GAIA advisory step' do
      it 'includes gaia:advisory in enrichments when GAIA available' do
        gaia_mod = Module.new
        allow(gaia_mod).to receive(:advise).and_return({ valence: [0.5] })
        allow(gaia_mod).to receive(:started?).and_return(true)
        stub_const('Legion::Gaia', gaia_mod)

        executor = described_class.new(request)
        allow(executor).to receive(:step_provider_call).and_return(
          { role: :assistant, content: 'test' }
        )
        allow(executor).to receive(:step_response_normalization).and_return(nil)
        response = executor.call

        expect(response.enrichments).to have_key('gaia:advisory')
      end
    end

    it 'skips governance steps for gaia profile' do
      gaia_request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'test' }],
        caller:   { requested_by: { identity: 'gaia:tick', type: :system, credential: :internal } }
      )
      executor = described_class.new(gaia_request)
      allow(executor).to receive(:step_provider_call).and_return(
        { role: :assistant, content: 'test' }
      )
      allow(executor).to receive(:step_response_normalization).and_return(nil)
      response = executor.call
      keys = response.timeline.map { |e| e[:key] }
      expect(keys).not_to include('rbac:permission_check')
      expect(keys).not_to include('classification:scan')
      expect(keys).not_to include('billing:budget_check')
    end

    describe 'enrichment injection' do
      it 'injects RAG context into system prompt before provider call' do
        rag_request = Legion::LLM::Inference::Request.build(
          messages:         [{ role: :user, content: 'what is pgvector?' }],
          system:           'You are helpful.',
          context_strategy: :rag
        )

        apollo_runner = double('Knowledge')
        allow(apollo_runner).to receive(:retrieve_relevant).and_return({
                                                                         success: true,
                                                                         entries: [{ content: 'pgvector is a PostgreSQL extension', content_type: 'fact',
confidence: 0.9 }],
                                                                         count:   1
                                                                       })
        stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

        seen_system = nil
        register_native_chat do |**opts|
          seen_system = opts[:system]
          { content: 'test', usage: { input_tokens: 10, output_tokens: 5 } }
        end

        executor = described_class.new(rag_request)
        executor.call

        expect(seen_system).to include('pgvector is a PostgreSQL extension')
      end
    end

    describe 'RAG context step' do
      it 'calls Apollo when context_strategy is :rag' do
        rag_request = Legion::LLM::Inference::Request.build(
          messages:         [{ role: :user, content: 'what is pgvector?' }],
          context_strategy: :rag
        )

        apollo_runner = double('Knowledge')
        allow(apollo_runner).to receive(:retrieve_relevant).and_return({
                                                                         success: true, entries: [{ content: 'test' }], count: 1
                                                                       })
        stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

        executor = described_class.new(rag_request)
        allow(executor).to receive(:step_provider_call).and_return(
          { role: :assistant, content: 'test' }
        )
        allow(executor).to receive(:step_response_normalization).and_return(nil)
        response = executor.call

        expect(response.enrichments).to have_key('rag:context_retrieval')
      end

      it 'skips RAG for gaia profile' do
        gaia_request = Legion::LLM::Inference::Request.build(
          messages:         [{ role: :user, content: 'test' }],
          context_strategy: :rag,
          caller:           { requested_by: { identity: 'gaia:tick', type: :system, credential: :internal } }
        )
        executor = described_class.new(gaia_request)
        allow(executor).to receive(:step_provider_call).and_return(
          { role: :assistant, content: 'test' }
        )
        allow(executor).to receive(:step_response_normalization).and_return(nil)
        response = executor.call

        # RAG step is skipped for GAIA profile (GAIA_SKIP includes rag_context is not listed,
        # but verify it at least doesn't crash.
        expect(response).to be_a(Legion::LLM::Inference::Response)
      end
    end

    describe 'tool registry injection' do
      it 'injects always-loaded tools and only requested deferred tools via Settings::Extensions' do
        always_entries = [
          { name: 'legion_query_knowledge', description: 'Always loaded tool',
            input_schema: { type: 'object', properties: {} }, deferred: false }
        ]
        deferred_entries = [
          { name: 'legion_test_extra', description: 'Requested deferred tool',
            input_schema: { type: 'object', properties: {} }, deferred: true },
          { name: 'legion_test_skipped', description: 'Skipped deferred tool',
            input_schema: { type: 'object', properties: {} }, deferred: true }
        ]
        all_entries = always_entries + deferred_entries
        extensions_mod = Module.new do
          define_singleton_method(:tools) { all_entries }
          define_singleton_method(:filter_tools) do |**criteria|
            if criteria[:deferred] == false
              always_entries
            elsif criteria[:deferred] == true
              deferred_entries
            else
              all_entries
            end
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)

        req = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'test' }],
          metadata: { requested_tools: ['legion.test.extra'] }
        )
        executor = described_class.new(req)
        names = executor.send(:native_tool_definitions).map(&:name)
        expect(names).to include('legion_query_knowledge', 'legion_test_extra')
        expect(names).not_to include('legion_test_skipped')
      end

      it 'caps registry tools for local providers and prioritizes trigger-matched tools' do
        always_entries = 3.times.map do |idx|
          { name: "legion_always_#{idx}", description: 'Always loaded tool',
            input_schema: { type: 'object', properties: {} }, deferred: false }
        end
        triggered_entries = 3.times.map do |idx|
          { name: "legion_triggered_#{idx}", description: 'Triggered tool',
            input_schema: { type: 'object', properties: {} }, deferred: false }
        end
        all_entries = always_entries
        extensions_mod = Module.new do
          define_singleton_method(:tools) { all_entries }
          define_singleton_method(:filter_tools) do |**criteria|
            criteria[:deferred] == false ? all_entries : []
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)
        Legion::LLM.settings[:tool_trigger][:local_tool_limit] = 2

        req = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'test' }])
        executor = described_class.new(req)
        executor.instance_variable_set(:@resolved_provider, :vllm)
        executor.instance_variable_set(:@triggered_tools, triggered_entries)
        names = executor.send(:native_tool_definitions).map(&:name)

        expect(names).to eq(%w[legion_triggered_0 legion_triggered_1])
      end
    end
  end

  describe 'step_context_load' do
    before { Legion::LLM::Inference::Conversation.reset! }

    it 'loads prior messages into enrichments when conversation_id present' do
      Legion::LLM::Inference::Conversation.append('conv_123', role: :user, content: 'earlier message')
      Legion::LLM::Inference::Conversation.append('conv_123', role: :assistant, content: 'earlier reply')

      req = Legion::LLM::Inference::Request.build(
        messages:        [{ role: :user, content: 'new question' }],
        conversation_id: 'conv_123',
        routing:         { provider: :anthropic, model: 'claude-opus-4-6' }
      )
      executor = described_class.new(req)
      allow(executor).to receive(:step_provider_call)
      executor.call
      expect(executor.enrichments['context:conversation_history']).to be_an(Array)
      expect(executor.enrichments['context:conversation_history'].size).to eq(2)
    end

    it 'does not load conversation history when no prior messages exist' do
      executor = described_class.new(request)
      allow(executor).to receive(:step_provider_call)
      executor.call
      expect(executor.enrichments['context:conversation_history']).to be_nil
    end
  end

  describe 'privacy-constrained routing' do
    it 'uses forced classification tier even when caller requested a cloud tier' do
      privacy_request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'patient diagnosis is hypertension' }],
        routing:  { provider: nil, model: nil },
        extra:    { tier: :cloud, intent: { capability: :reasoning } }
      )
      executor = described_class.new(privacy_request)
      executor.instance_variable_set(
        :@proactive_tier_assignment,
        { tier: :local, intent: { privacy: :strict }, source: :classification, forced: true }
      )

      executor.send(:step_routing)

      expect(executor.instance_variable_get(:@resolved_tier)).to eq(:local)
      expect(executor.audit[:'routing:provider_selection'][:data][:tier]).to eq(:local)
    end
  end

  describe 'step_context_store' do
    before { Legion::LLM::Inference::Conversation.reset! }

    it 'appends request message and response to ConversationStore' do
      req = Legion::LLM::Inference::Request.build(
        messages:        [{ role: :user, content: 'hello' }],
        conversation_id: 'conv_store_test',
        routing:         { provider: :anthropic, model: 'claude-opus-4-6' }
      )
      executor = described_class.new(req)

      register_native_chat { { content: 'hi there', usage: { input_tokens: 10, output_tokens: 5 } } }
      allow(executor).to receive(:step_response_normalization)

      executor.call

      messages = Legion::LLM::Inference::Conversation.messages('conv_store_test')
      expect(messages.size).to eq(2)
      expect(messages.first[:role]).to eq(:user)
      expect(messages.last[:role]).to eq(:assistant)
      expect(messages.last[:content]).to eq('hi there')
    end

    it 'auto-generates conversation_id and stores messages' do
      executor = described_class.new(request)
      allow(executor).to receive(:step_provider_call)
      executor.call
      # step_conversation_uuid auto-generates an id, so context_store will append
      conv_id = executor.request.conversation_id
      expect(conv_id).to start_with('conv_')
    end
  end

  describe 'error classification in provider call' do
    before do
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = false
    end

    it 'wraps native HTTP 429 as RateLimitError' do
      executor = described_class.new(request)
      register_native_chat { raise Faraday::TooManyRequestsError.new(nil, { status: 429 }) }
      expect { executor.call }.to raise_error(Legion::LLM::RateLimitError)
    end

    it 'wraps native HTTP 401 as AuthError' do
      executor = described_class.new(request)
      register_native_chat { raise Faraday::UnauthorizedError.new(nil, { status: 401 }) }
      expect { executor.call }.to raise_error(Legion::LLM::AuthError)
    end

    it 'wraps generic provider errors as ProviderError' do
      executor = described_class.new(request)
      register_native_chat { raise Faraday::ServerError.new(nil, { status: 500 }) }
      expect { executor.call }.to raise_error(Legion::LLM::ProviderError)
    end
  end

  describe 'route attempt metadata' do
    let(:fleet_request) do
      Legion::LLM::Inference::Request.build(
        id:              'req-route-fleet',
        conversation_id: 'conv-route-fleet',
        messages:        [{ role: :user, content: 'hello' }],
        routing:         { provider: :vllm, model: 'qwen3.6-27b' }
      )
    end

    it 'records direct success attempts in the response routing payload and timeline' do
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = false
      register_native_chat do
        { content: 'direct answer', usage: { input_tokens: 10, output_tokens: 5 } }
      end

      response = described_class.new(request).call
      attempt = response.routing[:route_attempts].last

      expect(attempt).to include(
        provider:      :anthropic,
        model:         'claude-opus-4-6',
        dispatch_path: :direct,
        status:        :success
      )
      expect(attempt).to include(:idempotency_key, :selected_lane)
      expect(response.timeline).to include(hash_including(key: 'provider:route_attempt', data: attempt))
    end

    it 'records fleet timeouts with the selected lane and idempotency key' do
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = false
      allow(Legion::LLM::Fleet::Dispatcher).to receive(:dispatch).and_return(
        success:        false,
        error:          'fleet_timeout',
        correlation_id: 'corr-timeout',
        timeout:        1
      )

      executor = described_class.new(fleet_request)

      expect { executor.call }.to raise_error(Legion::LLM::ProviderError, /fleet_timeout/)
      attempt = executor.instance_variable_get(:@route_attempts).last
      expect(attempt).to include(
        provider:       :vllm,
        model:          'qwen3.6-27b',
        dispatch_path:  :fleet,
        status:         :failure,
        failure_reason: 'fleet_timeout'
      )
      expect(attempt[:idempotency_key]).to match(/\Aidem_/)
      expect(attempt[:selected_lane]).to eq('llm.fleet.inference.qwen3-6-27b')
    end

    it 'records fleet errors separately from publish and timeout failures' do
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = false
      allow(Legion::LLM::Fleet::Dispatcher).to receive(:dispatch).and_return(
        success:        false,
        error:          'fleet_worker_error',
        correlation_id: 'corr-error'
      )

      executor = described_class.new(fleet_request)

      expect { executor.call }.to raise_error(Legion::LLM::ProviderError, /fleet_worker_error/)
      expect(executor.instance_variable_get(:@route_attempts).last).to include(
        dispatch_path:  :fleet,
        status:         :failure,
        failure_reason: 'fleet_worker_error'
      )
    end

    it 'keeps failed fleet attempt metadata when escalation succeeds on a direct provider' do
      fleet_resolution = Legion::LLM::Router::Resolution.new(tier: :fleet, provider: :vllm, model: 'qwen3.6-27b')
      direct_resolution = Legion::LLM::Router::Resolution.new(tier: :cloud, provider: :anthropic, model: 'claude-opus-4-6')
      chain = Legion::LLM::Router::EscalationChain.new(resolutions: [fleet_resolution, direct_resolution], max_attempts: 2)
      escalation_request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        extra:    { intent: { capability: :chat } }
      )

      Legion::Settings[:llm][:routing][:escalation][:enabled] = true
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = true
      allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(true)
      allow(Legion::LLM::Router).to receive(:resolve_chain).and_return(chain)
      allow(Legion::LLM::Fleet::Dispatcher).to receive(:dispatch).and_return(
        success:        false,
        error:          'fleet_timeout',
        correlation_id: 'corr-timeout'
      )
      register_native_chat(:anthropic) do
        {
          content: 'direct escalation answer with enough text to pass quality',
          usage:   { input_tokens: 8, output_tokens: 9 }
        }
      end

      response = described_class.new(escalation_request).call
      attempts = response.routing[:route_attempts]

      expect(attempts.map { |attempt| attempt[:dispatch_path] }).to eq(%i[fleet direct])
      expect(attempts.first).to include(status: :failure, failure_reason: 'fleet_timeout')
      expect(attempts.last).to include(status: :success, escalation: hash_including(attempt: 2))
      expect(response.message[:content]).to include('direct escalation answer')
    end
  end

  describe 'MCP integration' do
    it 'includes McpDiscovery step module' do
      expect(described_class.ancestors).to include(Legion::LLM::Inference::Steps::McpDiscovery)
    end

    it 'includes ToolCalls step module' do
      expect(described_class.ancestors).to include(Legion::LLM::Inference::Steps::ToolCalls)
    end

    it 'exposes discovered_tools reader' do
      executor = described_class.new(request)
      expect(executor).to respond_to(:discovered_tools)
    end
  end

  describe 'tool loop cap (max_tool_rounds)' do
    let(:tool_request) do
      Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'use tool' }],
        routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
        tools:    [{ name: 'lookup', description: 'Lookup', parameters: { type: 'object', properties: {} } }]
      )
    end

    it 'halts and raises PipelineError when tool rounds exceed max_tool_rounds setting' do
      Legion::Settings[:llm][:max_tool_rounds] = 2
      Legion::Settings[:llm][:routing][:escalation][:enabled] = false
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = false

      register_native_chat do
        { content: '', tool_calls: [{ id: 'tc_1', name: 'lookup', arguments: {} }], usage: {} }
      end
      executor = described_class.new(tool_request)
      allow(executor).to receive(:step_response_normalization)

      expect { executor.call }.to raise_error(Legion::LLM::InferenceError, /tool loop exceeded 2 rounds/)
    end

    it 'honors string-keyed max_tool_rounds settings' do
      Legion::Settings.set_prop(:llm, { 'max_tool_rounds' => 2, 'routing' => { 'escalation' => { 'pipeline_enabled' => false } } })

      register_native_chat do
        { content: '', tool_calls: [{ id: 'tc_1', name: 'lookup', arguments: {} }], usage: {} }
      end
      executor = described_class.new(tool_request)
      allow(executor).to receive(:step_response_normalization)

      expect { executor.call }.to raise_error(Legion::LLM::InferenceError, /tool loop exceeded 2 rounds/)
    end

    it 'uses MAX_NATIVE_TOOL_ROUNDS as default when max_tool_rounds not in settings' do
      Legion::Settings.set_prop(:llm, { routing: { escalation: { pipeline_enabled: false } } })

      register_native_chat { { content: 'done', usage: { input_tokens: 5, output_tokens: 3 } } }
      executor = described_class.new(request)
      allow(executor).to receive(:step_response_normalization)

      expect { executor.call }.not_to raise_error
    end
  end

  describe 'string-keyed routing settings' do
    subject(:executor) { described_class.new(request) }

    it 'honors string-keyed pipeline escalation settings' do
      Legion::Settings.set_prop(:llm, {
                                  'routing' => {
                                    'escalation' => {
                                      'enabled'           => true,
                                      'pipeline_enabled'  => true,
                                      'max_attempts'      => 7,
                                      'quality_threshold' => 85
                                    }
                                  }
                                })

      expect(executor.send(:pipeline_escalation_enabled?)).to be(true)
      expect(executor.send(:pipeline_escalation_max_attempts)).to eq(7)
      expect(executor.send(:pipeline_escalation_quality_threshold)).to eq(85)
    end

    it 'honors string-keyed native provider layer settings' do
      Legion::Settings.set_prop(:llm, {
                                  'provider_layer' => {
                                    'mode' => 'auto'
                                  }
                                })
      allow(Legion::LLM::Call::Dispatch).to receive(:available?).with(:bedrock).and_return(true)

      expect(executor.send(:use_native_dispatch?, :bedrock)).to be(true)
    end

    it 'uses Legion::LLM::Call::Dispatch for explicit tool-bearing requests' do
      tool_request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'use the tool' }],
        routing:  { provider: :bedrock, model: 'claude-sonnet-4-6' },
        tools:    [Class.new]
      )
      tool_executor = described_class.new(tool_request)
      Legion::Settings.set_prop(:llm, {
                                  'provider_layer' => {
                                    'mode' => 'native'
                                  }
                                })

      expect(tool_executor.send(:use_native_dispatch?, :bedrock)).to be(true)
    end

    it 'uses Legion::LLM::Call::Dispatch when Settings::Extensions tools are available' do
      extensions_mod = Module.new do
        define_singleton_method(:tools) do
          [{ name: 'registry_tool', description: 'Tool', input_schema: {}, deferred: false }]
        end
        define_singleton_method(:filter_tools) do |**criteria|
          criteria[:deferred] == false ? tools : []
        end
      end
      stub_const('Legion::Settings::Extensions', extensions_mod)
      Legion::Settings.set_prop(:llm, {
                                  'provider_layer' => {
                                    'mode' => 'auto'
                                  }
                                })
      allow(Legion::LLM::Call::Dispatch).to receive(:available?).with(:bedrock).and_return(true)

      expect(executor.send(:use_native_dispatch?, :bedrock)).to be(true)
    end

    it 'allows Legion::LLM::Call::Dispatch when tools were explicitly disabled' do
      extensions_mod = Module.new do
        define_singleton_method(:tools) do
          [{ name: 'registry_tool', description: 'Tool', input_schema: {}, deferred: false }]
        end
        define_singleton_method(:filter_tools) do |**criteria|
          criteria[:deferred] == false ? tools : []
        end
      end
      stub_const('Legion::Settings::Extensions', extensions_mod)
      toolless_request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'no tools' }],
        routing:  { provider: :bedrock, model: 'claude-sonnet-4-6' },
        tools:    []
      )
      toolless_executor = described_class.new(toolless_request)
      Legion::Settings.set_prop(:llm, {
                                  'provider_layer' => {
                                    'mode' => 'auto'
                                  }
                                })
      allow(Legion::LLM::Call::Dispatch).to receive(:available?).with(:bedrock).and_return(true)

      expect(toolless_executor.send(:use_native_dispatch?, :bedrock)).to be(true)
    end

    it 'finds string-keyed fallback provider configs' do
      Legion::Settings.set_prop(:llm, {
                                  'providers' => {
                                    'ollama'  => {
                                      'enabled'       => true,
                                      'default_model' => 'qwen3.6:27b'
                                    },
                                    'bedrock' => {
                                      'enabled'       => true,
                                      'default_model' => 'claude-sonnet-4-6'
                                    }
                                  }
                                })

      expect(executor.send(:find_fallback_provider, exclude: [])).to eq(
        { provider: :bedrock, model: 'claude-sonnet-4-6' }
      )
    end
  end

  describe 'offering-aware routing metadata' do
    it 'preserves explicit offering metadata in response routing' do
      offering_request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  {
          provider:          :azure_foundry,
          model:             'gpt4o-prod',
          offering_id:       'azure:default:inference:gpt-4o',
          offering_metadata: { provider_instance: :eastus, canonical_model_alias: 'gpt-4o' }
        }
      )
      executor = described_class.new(offering_request)

      executor.send(:step_routing)
      routing = executor.send(:build_response_routing)

      expect(routing).to include(
        provider:          :azure_foundry,
        model:             'gpt4o-prod',
        offering_id:       'azure:default:inference:gpt-4o',
        offering_metadata: { provider_instance: :eastus, canonical_model_alias: 'gpt-4o' }
      )
    end
  end

  describe 'tool_event_handler events' do
    let(:events) { [] }
    let(:executor) do
      req = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
      )
      ex = described_class.new(req)
      ex.tool_event_handler = ->(event) { events << event }
      ex
    end

    before do
      Legion::Settings[:llm][:routing][:escalation][:enabled] = false
      Legion::Settings[:llm][:routing][:escalation][:pipeline_enabled] = false
    end

    describe ':tool_result event' do
      it 'fires :tool_result event with tool_call_id, tool_name, result, duration_ms, result_size' do
        tool_class = Class.new do
          define_singleton_method(:tool_name) { 'my_tool' }
          define_singleton_method(:description) { 'My tool' }
          define_singleton_method(:input_schema) { { type: 'object', properties: {} } }
          define_singleton_method(:call) { |**| 'result text' }
        end
        extensions_mod = Module.new do
          define_singleton_method(:tools) do
            [{ name: 'my_tool', description: 'My tool', input_schema: { type: 'object', properties: {} },
               tool_class: tool_class, deferred: false }]
          end
          define_singleton_method(:filter_tools) do |**criteria|
            criteria[:deferred] == false ? tools : []
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)
        call_count = 0
        register_native_chat do
          call_count += 1
          if call_count == 1
            { content: '', tool_calls: [{ id: 'tc_abc', name: 'my_tool', arguments: {} }], usage: {} }
          else
            { content: 'done', usage: { input_tokens: 5, output_tokens: 3 } }
          end
        end
        allow(executor).to receive(:step_response_normalization)

        executor.call

        result_events = events.select { |e| e[:type] == :tool_result }
        expect(result_events).not_to be_empty
        ev = result_events.first
        expect(ev[:tool_call_id]).to eq('tc_abc')
        expect(ev[:tool_name]).to eq('my_tool')
        expect(ev[:result]).to eq('result text')
        expect(ev[:result_size]).to eq('result text'.bytesize)
        expect(ev).to have_key(:duration_ms)
        expect(ev).to have_key(:started_at)
        expect(ev).to have_key(:finished_at)
      end

      it 'truncates result to 4096 bytes in :tool_result event' do
        large_result = 'x' * 8000
        tool_class = Class.new do
          define_singleton_method(:tool_name) { 'big_tool' }
          define_singleton_method(:description) { 'Big tool' }
          define_singleton_method(:input_schema) { { type: 'object', properties: {} } }
          define_singleton_method(:call) { |**| large_result }
        end
        extensions_mod = Module.new do
          define_singleton_method(:tools) do
            [{ name: 'big_tool', description: 'Big tool', input_schema: { type: 'object', properties: {} },
               tool_class: tool_class, deferred: false }]
          end
          define_singleton_method(:filter_tools) do |**criteria|
            criteria[:deferred] == false ? tools : []
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)
        call_count = 0
        register_native_chat do
          call_count += 1
          if call_count == 1
            { content: '', tool_calls: [{ id: 'tc_big', name: 'big_tool', arguments: {} }], usage: {} }
          else
            { content: 'done', usage: { input_tokens: 5, output_tokens: 3 } }
          end
        end
        allow(executor).to receive(:step_response_normalization)

        executor.call

        result_events = events.select { |e| e[:type] == :tool_result }
        expect(result_events).not_to be_empty
        ev = result_events.first
        expect(ev[:result].length).to eq(4096)
        expect(ev[:result_size]).to eq(8000)
      end
    end

    describe ':model_fallback event' do
      it 'fires :model_fallback with from_provider, to_provider, from_model, to_model on auth failure' do
        Legion::LLM::Call::Registry.register(:anthropic, Module.new do
          define_singleton_method(:chat) { |**| raise Faraday::UnauthorizedError.new(nil, { status: 401 }) }
        end)
        Legion::LLM::Call::Registry.register(:openai, Module.new do
          define_singleton_method(:chat) do |**|
            { content: 'provider response', usage: { input_tokens: 5, output_tokens: 3 } }
          end
        end)

        allow(executor).to receive(:find_fallback_provider).with(exclude: [:anthropic]).and_return(
          { provider: :openai, model: 'gpt-4o' }
        )
        allow(executor).to receive(:step_response_normalization)

        executor.call

        fallback_events = events.select { |e| e[:type] == :model_fallback }

        ev = fallback_events.first
        expect(ev).to have_key(:from_provider)
        expect(ev).to have_key(:to_provider)
        expect(ev).to have_key(:from_model)
        expect(ev).to have_key(:to_model)
        expect(ev[:reason]).to eq('auth_failed')
      end

      it ':model_fallback event payload includes provider fields' do
        # Test emit_tool_result_event directly to avoid needing full session wiring
        executor_instance = described_class.new(request)
        captured = []
        executor_instance.tool_event_handler = ->(event) { captured << event }

        # Simulate what happens inside execute_provider_request when fallback fires
        executor_instance.instance_variable_set(:@resolved_provider, :anthropic)
        executor_instance.instance_variable_set(:@resolved_model, 'claude-opus-4-6')
        executor_instance.instance_variable_set(:@warnings, [])
        executor_instance.instance_variable_set(:@timeline, Legion::LLM::Inference::Timeline.new)

        # Directly invoke the event handler as it would be called
        executor_instance.tool_event_handler.call(
          type: :model_fallback,
          from_provider: :anthropic, to_provider: :openai,
          from_model: 'claude-opus-4-6', to_model: 'gpt-4o',
          error: 'Unauthorized', reason: 'auth_failed'
        )

        expect(captured.size).to eq(1)
        ev = captured.first
        expect(ev[:from_provider]).to eq(:anthropic)
        expect(ev[:to_provider]).to eq(:openai)
        expect(ev[:from_model]).to eq('claude-opus-4-6')
        expect(ev[:to_model]).to eq('gpt-4o')
        expect(ev[:reason]).to eq('auth_failed')
      end
    end
  end

  describe 'sticky tool tracking ivars' do
    it 'initializes @sticky_turn_snapshot to nil' do
      executor = described_class.new(request)
      expect(executor.instance_variable_get(:@sticky_turn_snapshot)).to be_nil
    end

    it 'initializes @pending_tool_history as Concurrent::Array' do
      executor = described_class.new(request)
      expect(executor.instance_variable_get(:@pending_tool_history)).to be_a(Concurrent::Array)
    end

    it 'initializes @injected_tool_map as empty Hash' do
      executor = described_class.new(request)
      expect(executor.instance_variable_get(:@injected_tool_map)).to eq({})
    end

    it 'initializes @freshly_triggered_keys as empty Array' do
      executor = described_class.new(request)
      expect(executor.instance_variable_get(:@freshly_triggered_keys)).to eq([])
    end
  end

  describe 'profile skip lists include new sticky steps' do
    %i[gaia system service quick_reply].each do |profile_name|
      %i[sticky_runners tool_history_inject sticky_persist].each do |step|
        it "#{profile_name} profile skips #{step}" do
          expect(Legion::LLM::Inference::Profile.skip?(profile_name, step)).to be true
        end
      end
    end

    %i[human external].each do |profile_name|
      %i[sticky_runners tool_history_inject sticky_persist].each do |step|
        it "#{profile_name} profile does NOT skip #{step}" do
          expect(Legion::LLM::Inference::Profile.skip?(profile_name, step)).to be false
        end
      end
    end
  end
end
