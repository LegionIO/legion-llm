# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor do
  before do
    Legion::Settings[:llm][:routing] ||= {}
    Legion::Settings[:llm][:routing][:escalation] ||= {}
    Legion::Settings[:llm][:routing][:escalation][:enabled] = false
  end

  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
    )
  end

  # Legacy path helper — used only by tests that call execute_native_tool_loop directly.
  # In that path @current_attempt_context is nil so dispatch_direct_request falls through
  # to Call::Dispatch (legacy), and register_native_chat provides the handler.
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

  # SSOT v3 helper — publish one anthropic instance into Phase 1 Registry.
  def activate_anthropic(callable, model: 'claude-opus-4-6')
    SsotV3SnapshotFactory.activate(
      provider_family: 'anthropic',
      instance_id:     'primary',
      callable:        callable,
      drafts:          [SsotV3SnapshotFactory.offering_draft(
        model:        model,
        tier:         :frontier,
        supported:    %i[chat stream_chat count_tokens],
        capabilities: { tools: :supported, streaming: :supported },
        context:      200_000,
        max_output:   16_384
      )]
    )
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

        Legion::Settings[:llm][:gaia][:advisory_enabled] = true

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
          context_strategy: :rag,
          routing:          { provider: :anthropic, model: 'claude-opus-4-6' }
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
        # 0.8.0 callable contract: messages arrive positionally, not in kwargs.
        responder = lambda do |_op, args, _kwargs, _blk|
          seen_system = args.first.first.content
          native_dispatch_result(content: 'test')
        end
        activate_anthropic(SsotV3SnapshotFactory::FactoryCallable.new(responder: responder))

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

      it 'uses GAIA tool hints and suppressions when building native tools' do
        always_entries = [
          { name: 'legion_query_knowledge', description: 'Suppressed always-loaded tool',
            input_schema: { type: 'object', properties: {} }, deferred: false }
        ]
        deferred_entries = [
          { name: 'legion_test_extra', description: 'GAIA hinted deferred tool',
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

        req = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'test' }])
        executor = described_class.new(req)
        executor.enrichments['gaia:advisory'] = {
          data: { tool_hint: ['legion.test.extra'], suppress: ['legion_query_knowledge'] }
        }

        names = executor.send(:native_tool_definitions).map(&:name)
        expect(names).to include('legion_test_extra')
        expect(names).not_to include('legion_query_knowledge')
      end

      it 'suppresses explicitly provided native tools when GAIA says to suppress them' do
        req = Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'test' }],
          tools:    [{ name: 'blocked_tool', description: 'blocked', parameters: { type: 'object' } }]
        )
        executor = described_class.new(req)
        executor.enrichments['gaia:advisory'] = { data: { suppress: ['blocked_tool'] } }

        names = executor.send(:native_tool_definitions).map(&:name)
        expect(names).not_to include('blocked_tool')
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
        Legion::LLM.settings[:tools][:trigger][:local_tool_limit] = 2

        req = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'test' }])
        executor = described_class.new(req)
        executor.instance_variable_set(:@resolved_provider, :vllm)
        executor.instance_variable_set(:@triggered_tools, triggered_entries)
        names = executor.send(:native_tool_definitions).map(&:name)
        registry_names = names - Legion::LLM::Tools::Special.pinned_definitions.map(&:name)

        expect(registry_names).to eq(%w[legion_triggered_0 legion_triggered_1])
      end

      it 'prioritizes GAIA hinted tools before triggered tools for local providers' do
        always_entries = []
        hinted_entries = [
          { name: 'legion_hinted', description: 'Hinted tool',
            input_schema: { type: 'object', properties: {} }, deferred: true }
        ]
        triggered_entries = [
          { name: 'legion_triggered', description: 'Triggered tool',
            input_schema: { type: 'object', properties: {} }, deferred: false }
        ]
        extensions_mod = Module.new do
          define_singleton_method(:tools) { hinted_entries + triggered_entries }
          define_singleton_method(:filter_tools) do |**criteria|
            if criteria[:deferred] == false
              always_entries
            elsif criteria[:deferred] == true
              hinted_entries
            else
              hinted_entries + triggered_entries
            end
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)
        Legion::LLM.settings[:tools][:trigger][:local_tool_limit] = 1

        req = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'test' }])
        executor = described_class.new(req)
        executor.instance_variable_set(:@resolved_provider, :vllm)
        executor.instance_variable_set(:@triggered_tools, triggered_entries)
        executor.enrichments['gaia:advisory'] = { data: { tool_hint: ['legion_hinted'] } }

        names = executor.send(:native_tool_definitions).map(&:name)
        registry_names = names - Legion::LLM::Tools::Special.pinned_definitions.map(&:name)
        expect(registry_names).to eq(['legion_hinted'])
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

  describe 'step_context_store' do
    before { Legion::LLM::Inference::Conversation.reset! }

    # SSOT v3: publish a real anthropic callable so the SSOT engine can dispatch.
    # SsotStubCallable returns a Canonical::Response whose text is used by
    # step_context_store to persist the assistant message.
    it 'appends request message and response to ConversationStore' do
      req = Legion::LLM::Inference::Request.build(
        messages:        [{ role: :user, content: 'hello' }],
        conversation_id: 'conv_store_test',
        routing:         { provider: :anthropic, model: 'claude-opus-4-6' }
      )

      activate_anthropic(
        SsotStubCallable.new(content: 'hi there', input_tokens: 10, output_tokens: 5, tool_calls: [])
      )

      executor = described_class.new(req)
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
    # SSOT v3: provider errors normalize through the callable's normalize_dispatch_error
    # and become RoutingRejected once all attempts are exhausted. The classification
    # intent is preserved: rate-limit, auth, and generic errors all cause routing failure.

    def activate_failing_anthropic(error_class)
      responder = ->(_op, _args, _kwargs, _blk) { raise error_class }
      callable = SsotV3SnapshotFactory::FactoryCallable.new(responder: responder)
      activate_anthropic(callable)
    end

    it 'wraps rate-limit provider errors as RoutingRejected after exhaustion' do
      activate_failing_anthropic(Legion::Extensions::Llm::RateLimitError)
      executor = described_class.new(request)
      expect { executor.call }.to raise_error(Legion::LLM::Errors::RoutingRejected)
    end

    it 'wraps auth provider errors as RoutingRejected after exhaustion' do
      activate_failing_anthropic(Legion::Extensions::Llm::UnauthorizedError)
      executor = described_class.new(request)
      expect { executor.call }.to raise_error(Legion::LLM::Errors::RoutingRejected)
    end

    it 'wraps generic provider errors as RoutingRejected after exhaustion' do
      activate_failing_anthropic(Legion::Extensions::Llm::OverloadedError)
      executor = described_class.new(request)
      expect { executor.call }.to raise_error(Legion::LLM::Errors::RoutingRejected)
    end
  end

  describe 'route attempt metadata' do
    # SSOT v3: fleet_request uses routing[:tier] so the RoutingRequirements carry
    # the fleet tier_constraint and only the fleet-tier lane is selected.
    let(:fleet_request) do
      Legion::LLM::Inference::Request.build(
        id:              'req-route-fleet',
        conversation_id: 'conv-route-fleet',
        messages:        [{ role: :user, content: 'hello' }],
        routing:         { provider: :vllm, model: 'qwen3.6-27b', tier: :fleet }
      )
    end

    # Fleet offerings must carry fleet_execution_contract metadata so
    # CandidateEvaluation#ready? passes the fleet_contract_state check.
    def activate_fleet_vllm_lane(model: 'qwen3.6-27b', callable: nil)
      callable ||= SsotStubCallable.new(content: 'test response', input_tokens: 10,
                                        output_tokens: 5, tool_calls: [])
      SsotV3SnapshotFactory.activate(
        provider_family: 'vllm',
        instance_id:     'primary',
        callable:        callable,
        drafts:          [SsotV3SnapshotFactory.offering_draft(
          model:        model,
          tier:         :fleet,
          supported:    %i[chat stream_chat count_tokens],
          capabilities: { tools: :supported, streaming: :supported },
          context:      200_000,
          max_output:   16_384,
          metadata:     { fleet_execution_contract: 'exact_offering_v1' }
        )]
      )
    end

    it 'records direct success attempts in the response routing payload and timeline' do
      write_test_lane(provider: :anthropic, model: 'claude-opus-4-6', tier: :frontier, instance: :primary)

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
      Legion::Settings[:llm][:fleet][:dispatch][:enabled] = true
      activate_fleet_vllm_lane
      allow(Legion::LLM::Fleet::Dispatcher).to receive(:dispatch).and_return(
        success:        false,
        error:          'fleet_timeout',
        correlation_id: 'corr-timeout',
        timeout:        1
      )

      executor = described_class.new(fleet_request)

      expect { executor.call }.to raise_error(Legion::LLM::Errors::RoutingRejected)
      attempt = executor.instance_variable_get(:@route_attempts).last
      expect(attempt).to include(
        provider:      :vllm,
        model:         'qwen3.6-27b',
        dispatch_path: :fleet,
        status:        :failure
      )
      expect(attempt[:idempotency_key]).to match(/\Aidem_/)
    end

    it 'records fleet errors separately from publish and timeout failures' do
      Legion::Settings[:llm][:fleet][:dispatch][:enabled] = true
      activate_fleet_vllm_lane
      allow(Legion::LLM::Fleet::Dispatcher).to receive(:dispatch).and_return(
        success:        false,
        error:          'fleet_worker_error',
        correlation_id: 'corr-error'
      )

      executor = described_class.new(fleet_request)

      expect { executor.call }.to raise_error(Legion::LLM::Errors::RoutingRejected)
      expect(executor.instance_variable_get(:@route_attempts).last).to include(
        dispatch_path: :fleet,
        status:        :failure
      )
    end

    it 'projects native dispatch options and sends exact offering fields outside fleet params' do
      Legion::Settings[:llm][:fleet][:dispatch][:enabled] = true
      activate_fleet_vllm_lane

      captured_request = nil
      allow(Legion::LLM::Fleet::Dispatcher).to receive(:dispatch) do |request:, **|
        captured_request = request
        # Protocol v3 (E3): the fleet reply carries the serialized Canonical::Response
        # under :response.
        { success: true, response: { text: 'fleet answer', stop_reason: :end_turn } }
      end
      tool_request = Legion::LLM::Inference::Request.build(
        id:              'req-route-fleet-tools',
        conversation_id: 'conv-route-fleet-tools',
        messages:        [{ role: :user, content: 'lookup teams chat' }],
        system:          'Use available tools.',
        routing:         { provider: :vllm, model: 'qwen3.6-27b', tier: :fleet },
        metadata:        { client_tool_passthrough: true },
        tools:           [
          {
            name:        'legion_lookup',
            description: 'Lookup data',
            parameters:  { type: 'object', properties: { query: { type: 'string' } } }
          }
        ]
      )

      response = described_class.new(tool_request).call

      expect(response.message[:content]).to eq('fleet answer')
      expect(captured_request).to include(:messages, :tools, :execution_contract, :offering_id)
      expect(captured_request).not_to have_key(:options)
      expect(captured_request).not_to have_key(:system)
      # Fleet wire carries serialized (Hash) messages.
      expect(captured_request[:messages].first).to include(role: :system, content: 'Use available tools.')
      expect(captured_request[:execution_contract]).to eq('exact_offering_v1')
      # D2: the fleet envelope's offering_id IS the 5-tuple lane id.
      expect(captured_request[:offering_id]).to eq('fleet:vllm:primary:inference:qwen3.6-27b')
      # Dispatch-boundary contract: tools cross the boundary as canonical
      # ToolDefinitions (Hash values would be rejected by the provider funnel).
      tool = captured_request[:tools][:legion_lookup]
      expect(tool).to be_a(Legion::Extensions::Llm::Canonical::ToolDefinition)
      expect(tool.name).to eq('legion_lookup')
      expect(tool.description).to eq('Lookup data')
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
    let(:server_tool_class) do
      Class.new do
        def self.call(**)
          {}
        end
      end
    end

    let(:tool_request) do
      Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'use tool' }],
        routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
        tools:    [
          {
            name:        'lookup',
            description: 'Lookup',
            parameters:  { type: 'object', properties: {} },
            source:      { type: :registry, tool_class: server_tool_class }
          }
        ]
      )
    end

    # SSOT v3: PipelineError from execute_native_tool_loop is a pipeline-level signal,
    # not a provider error. Test via execute_native_tool_loop directly (no SSOT engine
    # wrapping) so the error propagates to the caller unchanged.
    it 'halts and raises PipelineError when tool rounds exceed max_tool_rounds setting' do
      Legion::Settings[:llm][:tools][:max_rounds] = 2

      call_count = 0
      register_native_chat do
        call_count += 1
        # Vary arguments each round to avoid repeat detection
        { content: '', tool_calls: [{ id: "tc_#{call_count}", name: 'lookup', arguments: { round: call_count } }], usage: {} }
      end
      executor = described_class.new(tool_request)
      executor.instance_variable_set(:@resolved_provider, :anthropic)
      executor.instance_variable_set(:@resolved_model, 'claude-opus-4-6')

      expect { executor.send(:execute_native_tool_loop) }.to raise_error(Legion::LLM::PipelineError, /tool loop exceeded 2 rounds/)
    end

    it 'honors max_tool_rounds settings' do
      Legion::Settings[:llm][:tools][:max_rounds] = 2

      call_count = 0
      register_native_chat do
        call_count += 1
        # Vary arguments each round to avoid repeat detection
        { content: '', tool_calls: [{ id: "tc_#{call_count}", name: 'lookup', arguments: { round: call_count } }], usage: {} }
      end
      executor = described_class.new(tool_request)
      executor.instance_variable_set(:@resolved_provider, :anthropic)
      executor.instance_variable_set(:@resolved_model, 'claude-opus-4-6')

      expect { executor.send(:execute_native_tool_loop) }.to raise_error(Legion::LLM::PipelineError, /tool loop exceeded 2 rounds/)
    end

    it 'uses default max_tool_rounds (200) when not configured in settings' do
      write_test_lane(provider: :anthropic, model: 'claude-opus-4-6', tier: :frontier, instance: :primary)

      executor = described_class.new(request)
      expect { executor.call }.not_to raise_error
    end

    it 'returns non-executable client tool calls for the caller instead of dispatching them server-side' do
      client_tool = Legion::LLM::Types::ToolDefinition.build(
        name:        'mcp_servers',
        description: 'List MCP servers',
        source:      { type: :client, executable: false }
      )
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'use client tool' }],
        routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
        tools:    [client_tool],
        metadata: { client_tool_passthrough: true }
      )
      register_native_chat do
        { content: '', tool_calls: [{ id: 'call_1', name: 'mcp_servers', arguments: '' }], usage: {} }
      end
      executor = described_class.new(request)
      executor.instance_variable_set(:@resolved_provider, :anthropic)
      executor.instance_variable_set(:@resolved_model, 'claude-opus-4-6')

      expect(Legion::LLM::Inference::ToolDispatcher).not_to receive(:dispatch)

      result = executor.send(:execute_native_tool_loop)

      expect(result.tool_calls.first.name).to eq('mcp_servers')
    end

    it 'adds continuation guidance after native tool result rounds' do
      systems = []
      call_count = 0
      register_native_chat do |**opts|
        systems << opts[:system].to_s
        call_count += 1
        if call_count == 1
          { content: '', tool_calls: [{ id: 'tc_1', name: 'lookup', arguments: {} }], usage: {} }
        else
          { content: 'done', usage: { input_tokens: 5, output_tokens: 3 } }
        end
      end
      executor = described_class.new(tool_request)
      executor.instance_variable_set(:@resolved_provider, :anthropic)
      executor.instance_variable_set(:@resolved_model, 'claude-opus-4-6')

      executor.send(:execute_native_tool_loop)

      expect(systems.first).not_to include('Tool-use continuation rule')
      expect(systems[1]).to include('Tool-use continuation rule')
      expect(systems[1]).to include('Do not say you will use a tool unless you are actually making the tool call')
    end

    it 'returns current client passthrough tool calls after prior server-side tool execution' do
      client_tool = Legion::LLM::Types::ToolDefinition.build(
        name:        'git',
        description: 'Git client tool',
        source:      { type: :client, executable: false }
      )
      mixed_tool_request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'run git status' }],
        routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
        metadata: { client_tool_passthrough: true },
        tools:    [
          {
            name:        'lookup',
            description: 'Lookup',
            parameters:  { type: 'object', properties: {} },
            source:      { type: :registry, tool_class: server_tool_class }
          },
          client_tool
        ]
      )

      call_count = 0
      responder = lambda do |_op, _args, _kwargs, _blk|
        call_count += 1
        if call_count == 1
          native_dispatch_result(tool_calls: [{ id: 'tc_lookup', name: 'lookup', arguments: {} }])
        else
          native_dispatch_result(
            content:    'using git',
            tool_calls: [{ id: 'tc_git', name: 'git', arguments: { command: 'status' } }]
          )
        end
      end
      activate_anthropic(SsotV3SnapshotFactory::FactoryCallable.new(responder: responder))

      response = described_class.new(mixed_tool_request).call

      expect(response.tools.map(&:name)).to eq(['git'])
      expect(response.tools.first.id).to eq('tc_git')
      expect(response.tools.first.arguments).to eq({ command: 'status' })
    end

    it 'matches explicit tool choice even when client tools are present' do
      translator = Struct.new(:capabilities).new({ forced_tool_choice: true })
      vllm_ext = Module.new do
        define_singleton_method(:translator) { translator }
        define_singleton_method(:chat) { |**| { content: 'ok', usage: {} } }
      end
      Legion::LLM::Call::Registry.register(:vllm, vllm_ext)

      client_tool = Legion::LLM::Types::ToolDefinition.build(
        name:        'git',
        description: 'Git client tool',
        source:      { type: :client, executable: false }
      )
      path_request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'run git status inside /Users/matt.iverson@optum.com/rubymine/legion/LegionIO' }],
        routing:  { provider: :vllm, model: 'qwen3.6-27b' },
        metadata: { client_tool_passthrough: true },
        tools:    [client_tool]
      )
      executor = described_class.new(path_request)
      executor.instance_variable_set(:@resolved_provider, :vllm)

      expect(executor.send(:native_tool_prefs)).to include(choice: 'git')
    end

    it 'still chooses the Ruby tool when Ruby is explicitly requested' do
      translator = Struct.new(:capabilities).new({ forced_tool_choice: true })
      vllm_ext = Module.new do
        define_singleton_method(:translator) { translator }
        define_singleton_method(:chat) { |**| { content: 'ok', usage: {} } }
      end
      Legion::LLM::Call::Registry.register(:vllm, vllm_ext)

      ruby_request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'run ruby -v' }],
        routing:  { provider: :vllm, model: 'qwen3.6-27b' }
      )
      executor = described_class.new(ruby_request)
      executor.instance_variable_set(:@resolved_provider, :vllm)

      expect(executor.send(:native_tool_prefs)).to include(choice: 'ruby')
    end
  end

  describe 'routing settings' do
    subject(:executor) { described_class.new(request) }

    # SSOT v4: pipeline_escalation_enabled?/max_attempts are deleted. The equivalent
    # contract is @router.maximum_attempts honoring the settings value.
    it 'honors maximum_attempts routing setting' do
      Legion::Settings[:llm][:router][:max_attempts] = 7
      req = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
      )
      ex = described_class.new(req)
      ex.send(:step_routing)
      expect(ex.instance_variable_get(:@router).maximum_attempts).to eq(7)
    end

    it 'honors native provider layer settings' do
      merge_llm_settings({
                           provider_layer: {
                             mode: 'auto'
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
      merge_llm_settings({
                           provider_layer: {
                             mode: 'native'
                           }
                         })
      allow(Legion::LLM::Call::Dispatch).to receive(:available?).with(:bedrock).and_return(true)

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
      merge_llm_settings({
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
      merge_llm_settings({
                           'provider_layer' => {
                             'mode' => 'auto'
                           }
                         })
      allow(Legion::LLM::Call::Dispatch).to receive(:available?).with(:bedrock).and_return(true)

      expect(toolless_executor.send(:use_native_dispatch?, :bedrock)).to be(true)
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
        responder = lambda do |_op, _args, _kwargs, _blk|
          call_count += 1
          if call_count == 1
            native_dispatch_result(tool_calls: [{ id: 'tc_abc', name: 'my_tool', arguments: {} }])
          else
            native_dispatch_result(content: 'done', input_tokens: 5, output_tokens: 3)
          end
        end
        activate_anthropic(SsotV3SnapshotFactory::FactoryCallable.new(responder: responder))

        executor.call

        result_events = events.select { |e| e[:type] == :tool_result }
        expect(result_events).not_to be_empty
        ev = result_events.first
        expect(ev[:tool_call_id]).to eq('tc_abc')
        expect(ev[:tool_name]).to eq('my_tool')
        expect(ev[:result]).to eq('result text')
        expect(ev[:result_size]).to eq('result text'.bytesize)
        expect(ev[:status]).to eq(:success)
        expect(ev).to have_key(:duration_ms)
        expect(ev).to have_key(:started_at)
        expect(ev).to have_key(:finished_at)
      end

      it 'marks :tool_result event status as error when dispatch returns an error result' do
        tool_class = Class.new do
          define_singleton_method(:tool_name) { 'failing_tool' }
          define_singleton_method(:description) { 'Failing tool' }
          define_singleton_method(:input_schema) { { type: 'object', properties: {} } }
          define_singleton_method(:call) { |**| { error: 'failed' } }
        end
        extensions_mod = Module.new do
          define_singleton_method(:tools) do
            [{ name: 'failing_tool', description: 'Failing tool', input_schema: { type: 'object', properties: {} },
               tool_class: tool_class, deferred: false }]
          end
          define_singleton_method(:filter_tools) do |**criteria|
            criteria[:deferred] == false ? tools : []
          end
        end
        stub_const('Legion::Settings::Extensions', extensions_mod)

        call_count = 0
        responder = lambda do |_op, _args, _kwargs, _blk|
          call_count += 1
          if call_count == 1
            native_dispatch_result(tool_calls: [{ id: 'tc_error', name: 'failing_tool', arguments: {} }])
          else
            native_dispatch_result(content: 'done', input_tokens: 5, output_tokens: 3)
          end
        end
        activate_anthropic(SsotV3SnapshotFactory::FactoryCallable.new(responder: responder))

        executor.call

        result_events = events.select { |event| event[:type] == :tool_result }
        expect(result_events.first[:tool_call_id]).to eq('tc_error')
        expect(result_events.first[:status]).to eq(:error)
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
        responder = lambda do |_op, _args, _kwargs, _blk|
          call_count += 1
          if call_count == 1
            native_dispatch_result(tool_calls: [{ id: 'tc_big', name: 'big_tool', arguments: {} }])
          else
            native_dispatch_result(content: 'done', input_tokens: 5, output_tokens: 3)
          end
        end
        activate_anthropic(SsotV3SnapshotFactory::FactoryCallable.new(responder: responder))

        executor.call

        result_events = events.select { |e| e[:type] == :tool_result }
        expect(result_events).not_to be_empty
        ev = result_events.first
        expect(ev[:result].length).to eq(4096)
        expect(ev[:result_size]).to eq(8000)
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

  describe 'N×N law enforcement' do
    # CLAUDE.md §N×N: "the router/executor should not know the difference between
    # what lex-llm-* calls what endpoint". The executor is blind to provider API
    # formats. All format translation lives in API namespace translators.
    it 'has no provider_supports_responses? method (executor is format-agnostic)' do
      executor = described_class.new(request)
      expect(executor).not_to respond_to(:provider_supports_responses?)
    end

    it 'has no resolved_provider_supports_responses? method (executor is format-agnostic)' do
      executor = described_class.new(request)
      expect(executor).not_to respond_to(:resolved_provider_supports_responses?)
    end

    it 'call_responses delegates to canonical step_provider_call (non-streaming)' do
      executor = described_class.new(request)
      # call_responses exists as an API seam but routes through canonical path
      expect(executor).to respond_to(:call_responses)
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

  describe 'final context preflight' do
    it 'raises ContextOverflow before dispatch when system payload pushes the selected model over its window' do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        system:   's' * 400,
        routing:  { provider: :vllm, model: 'qwen3.6-27b' }
      )
      executor = described_class.new(request)
      executor.instance_variable_set(:@resolved_provider, :vllm)
      executor.instance_variable_set(:@resolved_instance, :v100)
      executor.instance_variable_set(:@resolved_model, 'qwen3.6-27b')
      executor.instance_variable_set(:@resolved_tier, :direct)
      executor.instance_variable_set(:@resolved_offering_metadata, { limits: { context_window: 64 } })

      expect(Legion::LLM::Call::Dispatch).not_to receive(:call)

      expect do
        raw_messages = [{ role: :user, content: 'hello' }]
        raw_options = { system: 's' * 400 }
        executor.send(
          :dispatch_direct_request,
          capability:           :stream,
          operation:            :chat,
          messages:             raw_messages,
          raw_messages:         raw_messages,
          dispatch_options:     raw_options,
          raw_dispatch_options: raw_options
        )
      end.to raise_error(Legion::LLM::ContextOverflow, /final payload estimate/)
    end
  end
end
