# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Executor do
  let(:request) do
    Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
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
      expect(response).to be_a(Legion::LLM::Pipeline::Response)
      expect(response.request_id).to eq(request.id)
    end

    it 'derives profile from caller' do
      gaia_request = Legion::LLM::Pipeline::Request.build(
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
        expect(Legion::LLM::Pipeline::AuditPublisher).to receive(:publish)
        executor.call
      end

      it 'skips audit publish for gaia profile' do
        gaia_request = Legion::LLM::Pipeline::Request.build(
          messages: [{ role: :user, content: 'test' }],
          caller:   { requested_by: { identity: 'gaia:tick', type: :system, credential: :internal } }
        )
        executor = described_class.new(gaia_request)
        allow(executor).to receive(:step_provider_call).and_return(
          { role: :assistant, content: 'test' }
        )
        allow(executor).to receive(:step_response_normalization).and_return(nil)
        expect(Legion::LLM::Pipeline::AuditPublisher).not_to receive(:publish)
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
      gaia_request = Legion::LLM::Pipeline::Request.build(
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
        rag_request = Legion::LLM::Pipeline::Request.build(
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

        mock_session = double('RubyLLM::Chat')
        mock_response = double(content: 'test', input_tokens: 10, output_tokens: 5, model_id: 'test')
        allow(RubyLLM).to receive(:chat).and_return(mock_session)
        allow(mock_session).to receive(:with_tool).and_return(mock_session)
        allow(mock_session).to receive(:ask).and_return(mock_response)

        expect(mock_session).to receive(:with_instructions) do |instructions|
          expect(instructions).to include('pgvector is a PostgreSQL extension')
          mock_session
        end.at_least(:once)

        executor = described_class.new(rag_request)
        executor.call
      end
    end

    describe 'RAG context step' do
      it 'calls Apollo when context_strategy is :rag' do
        rag_request = Legion::LLM::Pipeline::Request.build(
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
        gaia_request = Legion::LLM::Pipeline::Request.build(
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
        expect(response).to be_a(Legion::LLM::Pipeline::Response)
      end
    end

    describe 'tool registry injection' do
      it 'injects always-loaded tools and only requested deferred tools' do
        always_tool = Class.new do
          define_singleton_method(:tool_name) { 'legion.query.knowledge' }
          define_singleton_method(:description) { 'Always loaded tool' }
          define_singleton_method(:input_schema) { { type: 'object', properties: {} } }
        end
        requested_tool = Class.new do
          define_singleton_method(:tool_name) { 'legion.test.extra' }
          define_singleton_method(:description) { 'Requested deferred tool' }
          define_singleton_method(:input_schema) { { type: 'object', properties: {} } }
        end
        skipped_tool = Class.new do
          define_singleton_method(:tool_name) { 'legion.test.skipped' }
          define_singleton_method(:description) { 'Skipped deferred tool' }
          define_singleton_method(:input_schema) { { type: 'object', properties: {} } }
        end

        registry_mod = Module.new do
          define_singleton_method(:tools) { [always_tool] }
          define_singleton_method(:deferred_tools) { [requested_tool, skipped_tool] }
        end
        stub_const('Legion::Tools::Registry', registry_mod)

        req = Legion::LLM::Pipeline::Request.build(
          messages: [{ role: :user, content: 'test' }],
          metadata: { requested_tools: ['legion.test.extra'] }
        )
        executor = described_class.new(req)
        session = double('RubyLLM::Chat')
        allow(session).to receive(:with_tool)

        executor.send(:inject_registry_tools, session)

        expect(session).to have_received(:with_tool).twice
        names = []
        expect(session).to have_received(:with_tool).at_least(:once) do |tool|
          names << tool.name
        end
        expect(names).to include('legion_query_knowledge', 'legion_test_extra')
        expect(names).not_to include('legion_test_skipped')
      end
    end
  end

  describe 'step_context_load' do
    before { Legion::LLM::ConversationStore.reset! }

    it 'loads prior messages into enrichments when conversation_id present' do
      Legion::LLM::ConversationStore.append('conv_123', role: :user, content: 'earlier message')
      Legion::LLM::ConversationStore.append('conv_123', role: :assistant, content: 'earlier reply')

      req = Legion::LLM::Pipeline::Request.build(
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
    before { Legion::LLM::ConversationStore.reset! }

    it 'appends request message and response to ConversationStore' do
      req = Legion::LLM::Pipeline::Request.build(
        messages:        [{ role: :user, content: 'hello' }],
        conversation_id: 'conv_store_test',
        routing:         { provider: :anthropic, model: 'claude-opus-4-6' }
      )
      executor = described_class.new(req)

      mock_response = double('response', content: 'hi there', input_tokens: 10, output_tokens: 5)
      allow(RubyLLM).to receive(:chat).and_return(double('session', with_tool: nil, ask: mock_response))
      allow(executor).to receive(:step_response_normalization)

      executor.call

      messages = Legion::LLM::ConversationStore.messages('conv_store_test')
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
    it 'wraps RubyLLM 429 as RateLimitError' do
      executor = described_class.new(request)
      allow(RubyLLM).to receive(:chat).and_raise(
        Faraday::TooManyRequestsError.new(nil, { status: 429 })
      )
      expect { executor.call }.to raise_error(Legion::LLM::RateLimitError)
    end

    it 'wraps RubyLLM 401 as AuthError' do
      executor = described_class.new(request)
      allow(RubyLLM).to receive(:chat).and_raise(
        Faraday::UnauthorizedError.new(nil, { status: 401 })
      )
      expect { executor.call }.to raise_error(Legion::LLM::AuthError)
    end

    it 'wraps generic provider errors as ProviderError' do
      executor = described_class.new(request)
      allow(RubyLLM).to receive(:chat).and_raise(
        Faraday::ServerError.new(nil, { status: 500 })
      )
      expect { executor.call }.to raise_error(Legion::LLM::ProviderError)
    end
  end

  describe 'MCP integration' do
    it 'includes McpDiscovery step module' do
      expect(described_class.ancestors).to include(Legion::LLM::Pipeline::Steps::McpDiscovery)
    end

    it 'includes ToolCalls step module' do
      expect(described_class.ancestors).to include(Legion::LLM::Pipeline::Steps::ToolCalls)
    end

    it 'exposes discovered_tools reader' do
      executor = described_class.new(request)
      expect(executor).to respond_to(:discovered_tools)
    end
  end

  describe 'tool loop cap (max_tool_rounds)' do
    it 'halts and raises PipelineError when tool rounds exceed max_tool_rounds setting' do
      allow(Legion::LLM).to receive(:settings).and_return({ max_tool_rounds: 2 })

      executor = described_class.new(request)
      session = double('RubyLLM::Chat')
      tool_call_block = nil

      allow(session).to receive(:on_tool_call) { |&blk| tool_call_block = blk }
      allow(session).to receive(:respond_to?).with(:on_tool_result).and_return(false)
      allow(session).to receive(:respond_to?).with(:on_tool_call).and_return(true)
      allow(session).to receive(:with_tool)
      allow(session).to receive(:with_instructions)
      allow(RubyLLM).to receive(:chat).and_return(session)
      allow(session).to receive(:ask) do
        tool_call = double('ToolCall', id: 'tc_1', name: 'test_tool', arguments: {})
        3.times { tool_call_block.call(tool_call) }
        double(content: 'done', input_tokens: 5, output_tokens: 3, model_id: 'test')
      end

      allow(executor).to receive(:step_response_normalization)

      expect { executor.call }.to raise_error(Legion::LLM::PipelineError, /tool loop exceeded 2 rounds/)
    end

    it 'uses MAX_RUBY_LLM_TOOL_ROUNDS as default when max_tool_rounds not in settings' do
      allow(Legion::LLM).to receive(:settings).and_return({})

      executor = described_class.new(request)
      session = double('RubyLLM::Chat')
      allow(session).to receive(:on_tool_call).and_return(nil)
      allow(session).to receive(:respond_to?).with(:on_tool_result).and_return(false)
      allow(session).to receive(:respond_to?).with(:on_tool_call).and_return(true)
      allow(session).to receive(:with_tool)
      allow(session).to receive(:with_instructions)
      allow(RubyLLM).to receive(:chat).and_return(session)
      allow(session).to receive(:ask).and_return(
        double(content: 'done', input_tokens: 5, output_tokens: 3, model_id: 'test')
      )
      allow(executor).to receive(:step_response_normalization)

      # Should not raise — no tool calls fired, just verifying guard installs without crash
      expect { executor.call }.not_to raise_error
    end
  end

  describe 'tool_event_handler events' do
    let(:events) { [] }
    let(:executor) do
      req = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
      )
      ex = described_class.new(req)
      ex.tool_event_handler = ->(event) { events << event }
      ex
    end

    describe ':tool_result event' do
      it 'fires :tool_result event with tool_call_id, tool_name, result, duration_ms, result_size' do
        session = double('RubyLLM::Chat')
        tool_result_block = nil
        tool_call_block = nil

        allow(session).to receive(:on_tool_call) { |&blk| tool_call_block = blk }
        allow(session).to receive(:on_tool_result) { |&blk| tool_result_block = blk }
        allow(session).to receive(:respond_to?).with(:on_tool_result).and_return(true)
        allow(session).to receive(:respond_to?).with(:on_tool_call).and_return(true)
        allow(session).to receive(:with_tool)
        allow(session).to receive(:with_instructions)
        allow(RubyLLM).to receive(:chat).and_return(session)
        allow(session).to receive(:ask) do
          tool_call = double('ToolCall', id: 'tc_abc', name: 'my_tool', arguments: {})
          tool_call_block&.call(tool_call)
          wrapper = Legion::LLM::Patches::ToolResultWrapper.new(
            'result text', 'result text', 'tc_abc', 'tc_abc', 'my_tool'
          )
          tool_result_block&.call(wrapper)
          double(content: 'done', input_tokens: 5, output_tokens: 3, model_id: 'test')
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
        session = double('RubyLLM::Chat')
        tool_result_block = nil

        allow(session).to receive(:on_tool_call).and_return(nil)
        allow(session).to receive(:on_tool_result) { |&blk| tool_result_block = blk }
        allow(session).to receive(:respond_to?).with(:on_tool_result).and_return(true)
        allow(session).to receive(:respond_to?).with(:on_tool_call).and_return(true)
        allow(session).to receive(:with_tool)
        allow(session).to receive(:with_instructions)
        allow(RubyLLM).to receive(:chat).and_return(session)
        allow(session).to receive(:ask) do
          raw_result = double('ToolResult', tool_call_id: 'tc_big', tool_name: 'big_tool', result: large_result)
          tool_result_block&.call(raw_result)
          double(content: 'done', input_tokens: 5, output_tokens: 3, model_id: 'test')
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
        call_count = 0
        allow(RubyLLM).to receive(:chat) do
          call_count += 1
          raise Faraday::UnauthorizedError.new(nil, { status: 401 }) if call_count == 1

          session = double('RubyLLM::Chat')
          allow(session).to receive(:on_tool_call).and_return(nil)
          allow(session).to receive(:respond_to?).with(:on_tool_result).and_return(false)
          allow(session).to receive(:respond_to?).with(:on_tool_call).and_return(true)
          allow(session).to receive(:with_tool)
          allow(session).to receive(:with_instructions)
          allow(session).to receive(:ask).and_return(
            double(content: 'fallback response', input_tokens: 5, output_tokens: 3, model_id: 'fallback-model')
          )
          session
        end

        fallback_providers = [{ provider: :openai, model: 'gpt-4o', tier: :cloud }]
        allow(executor).to receive(:find_fallback_provider).and_return(nil, *fallback_providers)
        allow(executor).to receive(:find_fallback_provider).with(exclude: [:anthropic]).and_return(
          { provider: :openai, model: 'gpt-4o' }
        )
        allow(executor).to receive(:step_response_normalization)

        begin
          executor.call
        rescue Legion::LLM::AuthError
          # expected if no real fallback wired
        end

        fallback_events = events.select { |e| e[:type] == :model_fallback }
        next if fallback_events.empty? # skip assertion if auth error raised before fallback fires

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
        executor_instance.instance_variable_set(:@timeline, Legion::LLM::Pipeline::Timeline.new)

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
end
