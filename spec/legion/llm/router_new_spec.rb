# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'

# Per-request Router CLASS spec (SSOT v4). Exercises the Router instance lifecycle:
# construction validation, next_lane selection/rejection, next_attempt state
# management, classify outcome classification, and the 4 class-level status queries.
RSpec.describe Legion::LLM::Router, :ssot_v3 do
  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build a real Inference::Request via the deterministic test path.
  # Accepts all the fields the Router ctor needs to derive its internal state.
  def build_request(seed: 'ab' * 16, messages: [], routing: {}, client_model: nil,
                    tools: nil, tool_choice: nil, thinking: nil, response_format: nil,
                    system: nil, tokens: { max: 4096 }, extra: {}, stream: false)
    Legion::LLM::Inference::Request.build_for_test(
      routing_seed: seed, messages: messages, routing: routing,
      client_model: client_model, tools: tools, tool_choice: tool_choice,
      thinking: thinking, response_format: response_format, system: system,
      tokens: tokens, extra: extra, stream: stream
    )
  end

  # Build a Router instance with sensible defaults. Callers override individual kwargs.
  def build_router(request: nil, operation: :chat, body_model: nil, **request_kwargs)
    req = request || build_request(**request_kwargs)
    Legion::LLM::Router.new(request: req, operation: operation, body_model: body_model)
  end

  # Activate a lane in the Registry via the snapshot factory.
  def activate_lane(provider: :vllm, instance_id: 'primary', model: 'gemma-12b',
                    tier: :local, supported: %i[chat stream_chat count_tokens],
                    capabilities: { streaming: :supported, tools: :supported },
                    context: 200_000, max_output: 16_384, callable: nil)
    SsotV3SnapshotFactory.activate(
      provider_family: provider.to_s,
      instance_id:     instance_id,
      callable:        callable || SsotV3SnapshotFactory::FactoryCallable.new,
      drafts:          [SsotV3SnapshotFactory.offering_draft(
        model: model, tier: tier, supported: supported,
        capabilities: capabilities, context: context, max_output: max_output
      )]
    )
  end

  # Build a ProviderOutcome for classify tests.
  def provider_outcome(kind:, reason: 'test')
    Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: kind, reason: reason)
  end

  # Build a SelectionDispatch::Result for classify tests.
  def dispatch_result(kind: :success, reason: 'ok')
    outcome = provider_outcome(kind: kind, reason: reason)
    if kind == :success
      Legion::LLM::Call::SelectionDispatch::Result.success(value: { text: 'hello' })
    else
      Legion::LLM::Call::SelectionDispatch::Result.failure(outcome: outcome)
    end
  end

  before do
    # Ensure router settings are populated (spec_helper already merges defaults,
    # but be explicit about the keys Router reads).
    Legion::Settings[:llm][:router] ||= Legion::LLM::Settings::Router.defaults
    Legion::Settings[:extensions][:llm] ||= {}
  end

  # ===========================================================================
  # Constructor validation
  # ===========================================================================

  describe '#initialize' do
    context 'valid inputs' do
      it 'builds a Router instance for a :chat operation' do
        activate_lane
        router = build_router
        expect(router).to be_a(Legion::LLM::Router)
        expect(router.operation).to eq(:chat)
      end

      it 'derives pins from trusted_constraints' do
        activate_lane(provider: :vllm, model: 'gemma-12b')
        router = build_router(routing: { provider: 'vllm', model: 'gemma-12b' })
        expect(router.provider_pin).to eq(:vllm)
        expect(router.model_pin).to eq('gemma-12b')
      end

      it 'carries the body_model through' do
        activate_lane
        router = build_router(body_model: 'some-model')
        expect(router.body_model).to eq('some-model')
      end

      it 'initializes with zero exclusions and zero consumed targets' do
        activate_lane
        router = build_router
        expect(router.exclusions).to be_empty
        expect(router.consumed_targets).to be_empty
      end

      it 'derives maximum_attempts from settings' do
        Legion::Settings[:llm][:router][:max_attempts] = 5
        router = build_router
        expect(router.maximum_attempts).to eq(5)
      end

      it 'derives affinity_strength_bps from settings' do
        Legion::Settings[:llm][:router][:affinity_strength_bps] = 7_500
        router = build_router
        expect(router.affinity_strength_bps).to eq(7_500)
      end

      it 'derives instance_pin from trusted_constraints' do
        activate_lane(provider: :vllm, instance_id: 'apollo', model: 'gemma-12b')
        router = build_router(routing: { instance: 'apollo' })
        expect(router.instance_pin).to eq('apollo')
      end

      it 'derives tier_pin from trusted routing constraints' do
        activate_lane(provider: :vllm, model: 'gemma-12b', tier: :local)
        router = build_router(routing: { tier: 'local' })
        expect(router.tier_pin).to eq(:local)
      end

      it 'tier_pin is nil when unconstrained' do
        router = build_router
        expect(router.tier_pin).to be_nil
      end

      it 'instance_pin is nil when unconstrained' do
        router = build_router
        expect(router.instance_pin).to be_nil
      end

      it 'maximum_attempts uses trusted override when present' do
        activate_lane(provider: :vllm, model: 'gemma-12b')
        # The router max_attempts setting default (3) is the per-request ceiling;
        # a trusted X-Legion-Max-Attempts within that ceiling overrides the
        # setting for this one request. reset! rebuilds the snapshot from the live
        # defaults so the ceiling is deterministic regardless of test order.
        Legion::LLM::Routing::SettingsState.reset!
        req = Legion::LLM::Inference::Request.build_for_test(
          routing_seed: 'ab' * 16, messages: [],
          routing: {}, trusted_constraints: Legion::LLM::Routing::HeaderConstraints.from_internal(
            provider: nil, instance_id: nil, model: nil, tier: nil,
            maximum_attempts: 2,
            settings_snapshot: Legion::LLM::Routing::SettingsState.current
          )
        )
        router = build_router(request: req)
        expect(router.maximum_attempts).to eq(2)
      end
    end

    context 'invalid operation' do
      it 'raises ArgumentError for an unrecognized operation' do
        expect { build_router(operation: :nonsense) }.to raise_error(ArgumentError, /invalid operation/)
      end
    end

    context 'invalid routing seed' do
      it 'raises Errors::InvalidRoutingContext for a malformed seed' do
        expect do
          build_router(seed: 'too-short')
        end.to raise_error(Legion::LLM::Errors::InvalidRoutingContext)
      end

      it 'raises Errors::InvalidRoutingContext for a seed with invalid hex chars' do
        expect do
          build_router(seed: 'zz' * 16)
        end.to raise_error(Legion::LLM::Errors::InvalidRoutingContext)
      end
    end

    context 'model_pin resolution' do
      it 'uses trusted model when present' do
        router = build_router(routing: { model: 'explicit-model' })
        expect(router.model_pin).to eq('explicit-model')
      end

      it 'uses honored body-model hint when no trusted model' do
        Legion::Settings[:llm][:router][:allow_body_routing_hints] = true
        router = build_router(client_model: 'hint-model', body_model: 'hint-model')
        expect(router.model_pin).to eq('hint-model')
      ensure
        Legion::Settings[:llm][:router][:allow_body_routing_hints] = false
      end

      it 'is nil when unconstrained' do
        router = build_router
        expect(router.model_pin).to be_nil
      end
    end

    context 'required_capabilities derivation' do
      it 'includes :streaming for :stream_chat' do
        router = build_router(operation: :stream_chat)
        expect(router.required_capabilities).to include(:streaming)
      end

      it 'includes :embedding for :embed' do
        router = build_router(operation: :embed)
        expect(router.required_capabilities).to include(:embedding)
      end

      it 'includes :tools when request has tools' do
        router = build_router(tools: [{ name: 'search', description: 'Search' }])
        expect(router.required_capabilities).to include(:tools)
      end

      it 'includes :thinking when thinking is enabled' do
        router = build_router(thinking: { enabled: true, budget_tokens: 1024 })
        expect(router.required_capabilities).to include(:thinking)
      end

      it 'includes :vision when messages contain image blocks' do
        messages = [{ role: :user, content: [{ type: :image, source_type: :url, data: 'https://example.com/img.png', media_type: 'image/png' }] }]
        router = build_router(messages: messages)
        expect(router.required_capabilities).to include(:vision)
      end

      it 'includes :structured_output when response_format is json_object' do
        router = build_router(response_format: { type: :json_object })
        expect(router.required_capabilities).to include(:structured_output)
      end

      it 'returns an empty frozen array for a plain chat' do
        router = build_router
        expect(router.required_capabilities).to eq([])
        expect(router.required_capabilities).to be_frozen
      end

      # ---------------------------------------------------------------
      # Operation base capabilities (all operations)
      # ---------------------------------------------------------------

      it 'includes :image for :image operation' do
        router = build_router(operation: :image)
        expect(router.required_capabilities).to include(:image)
      end

      it 'includes :audio_transcription for :transcribe operation' do
        router = build_router(operation: :transcribe)
        expect(router.required_capabilities).to include(:audio_transcription)
      end

      it 'returns [] for :translate operation (no base capabilities)' do
        router = build_router(operation: :translate)
        expect(router.required_capabilities).to eq([])
      end

      it 'includes :audio_speech for :speak operation' do
        router = build_router(operation: :speak)
        expect(router.required_capabilities).to include(:audio_speech)
      end

      it 'includes :moderation for :moderate operation' do
        router = build_router(operation: :moderate)
        expect(router.required_capabilities).to include(:moderation)
      end

      it 'returns [] for :count_tokens operation (no base capabilities)' do
        router = build_router(operation: :count_tokens)
        expect(router.required_capabilities).to eq([])
      end

      # ---------------------------------------------------------------
      # Shape trigger: tool_choice modes
      # ---------------------------------------------------------------

      it 'includes :tools when tool_choice mode is :tool with a name' do
        router = build_router(tool_choice: { mode: :tool, name: 'web_search' })
        expect(router.required_capabilities).to include(:tools)
      end

      it 'includes :tools when tool_choice mode is :any' do
        router = build_router(tool_choice: { mode: :any })
        expect(router.required_capabilities).to include(:tools)
      end

      it 'does not include :tools when tool_choice mode is :auto (without tools array)' do
        router = build_router(tools: nil, tool_choice: { mode: :auto })
        expect(router.required_capabilities).not_to include(:tools)
      end

      it 'does not include :tools when tool_choice mode is :none (without tools array)' do
        router = build_router(tools: nil, tool_choice: { mode: :none })
        expect(router.required_capabilities).not_to include(:tools)
      end

      # ---------------------------------------------------------------
      # Shape trigger: message content blocks → :tools
      # ---------------------------------------------------------------

      it 'includes :tools when messages contain a :tool_use content block' do
        messages = [
          { role: :assistant, content: [
            { type: :tool_use, id: 'tu_1', name: 'web_search', input: { query: 'hello' } }
          ] }
        ]
        router = build_router(messages: messages)
        expect(router.required_capabilities).to include(:tools)
      end

      it 'includes :tools when messages contain a :tool_result content block' do
        messages = [
          { role: :user, content: [
            { type: :tool_result, tool_use_id: 'tu_1', text: 'result text' }
          ] }
        ]
        router = build_router(messages: messages)
        expect(router.required_capabilities).to include(:tools)
      end

      it 'does not include :tools when messages have only :text content blocks' do
        messages = [{ role: :user, content: [{ type: :text, text: 'Hello world' }] }]
        router = build_router(messages: messages)
        expect(router.required_capabilities).not_to include(:tools)
      end

      # ---------------------------------------------------------------
      # Shape trigger: thinking
      # ---------------------------------------------------------------

      it 'includes :thinking when thinking has budget_tokens but no :enabled key' do
        router = build_router(thinking: { budget_tokens: 2048 })
        expect(router.required_capabilities).to include(:thinking)
      end

      it 'does not include :thinking when thinking is explicitly disabled' do
        router = build_router(thinking: { enabled: false })
        expect(router.required_capabilities).not_to include(:thinking)
      end

      it 'includes :thinking when messages contain a :thinking content block' do
        messages = [
          { role: :assistant, content: [
            { type: :thinking, text: 'Let me reason step by step...' }
          ] }
        ]
        router = build_router(messages: messages)
        expect(router.required_capabilities).to include(:thinking)
      end

      # ---------------------------------------------------------------
      # Shape trigger: vision
      # ---------------------------------------------------------------

      it 'does not include :vision when messages have only :text content blocks' do
        messages = [{ role: :user, content: [{ type: :text, text: 'describe this image' }] }]
        router = build_router(messages: messages)
        expect(router.required_capabilities).not_to include(:vision)
      end

      it 'does not include :vision when message content is a plain String' do
        messages = [{ role: :user, content: 'just a plain string' }]
        router = build_router(messages: messages)
        expect(router.required_capabilities).not_to include(:vision)
      end

      # ---------------------------------------------------------------
      # Shape trigger: structured_output
      # ---------------------------------------------------------------

      it 'includes :structured_output when response_format type is :json_schema' do
        router = build_router(response_format: { type: :json_schema, schema: { type: 'object' } })
        expect(router.required_capabilities).to include(:structured_output)
      end

      it 'includes :structured_output when response_format has nonempty schema without type field' do
        router = build_router(response_format: { schema: { properties: { name: { type: 'string' } } } })
        expect(router.required_capabilities).to include(:structured_output)
      end

      it 'does not include :structured_output when response_format type is :text' do
        router = build_router(response_format: { type: :text })
        expect(router.required_capabilities).not_to include(:structured_output)
      end

      it 'does not include :structured_output when response_format schema is empty' do
        router = build_router(response_format: { type: :text, schema: {} })
        expect(router.required_capabilities).not_to include(:structured_output)
      end

      # ---------------------------------------------------------------
      # Deduplication
      # ---------------------------------------------------------------

      it 'deduplicates :tools when triggered by both tools array and a :tool_use block' do
        messages = [
          { role: :assistant, content: [{ type: :tool_use, id: 'tu_1', name: 'search', input: {} }] }
        ]
        router = build_router(tools: [{ name: 'search', description: 'Search' }], messages: messages)
        expect(router.required_capabilities.count(:tools)).to eq(1)
      end

      it 'deduplicates :streaming (appears once even for stream_chat)' do
        router = build_router(operation: :stream_chat)
        expect(router.required_capabilities.count(:streaming)).to eq(1)
      end

      # ---------------------------------------------------------------
      # OpenAI Responses dialect: :responses must NOT be inferred
      # ---------------------------------------------------------------

      it 'never includes :responses for a chat request' do
        router = build_router(messages: [{ role: :user, content: 'hello' }])
        expect(router.required_capabilities).not_to include(:responses)
      end

      it 'never includes :responses for a stream_chat request' do
        router = build_router(operation: :stream_chat, messages: [{ role: :user, content: 'hello' }], stream: true)
        expect(router.required_capabilities).not_to include(:responses)
      end

      it 'never includes :responses even with tools present' do
        router = build_router(tools: [{ name: 'code_interpreter', description: 'Runs code' }])
        expect(router.required_capabilities).not_to include(:responses)
      end

      # ---------------------------------------------------------------
      # Return value contract: all caps are canonical
      # ---------------------------------------------------------------

      it 'returns only canonical capability Symbols for a fully-featured request' do
        canonical = Legion::Extensions::Llm::Capabilities::CANONICAL
        messages = [
          { role: :user, content: [
            { type: :image, source_type: :url, data: 'https://example.com/img.png', media_type: 'image/png' }
          ] }
        ]
        router = build_router(
          operation:       :stream_chat,
          tools:           [{ name: 'search', description: 'Search' }],
          thinking:        { enabled: true, budget_tokens: 1024 },
          response_format: { type: :json_schema, schema: { type: 'object' } },
          messages:        messages
        )
        router.required_capabilities.each do |cap|
          expect(canonical).to include(cap), "#{cap.inspect} is not a canonical capability"
        end
      end
    end

    context 'input_bound derivation' do
      it 'includes framing overhead' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 512
        router = build_router(messages: [], system: nil)
        expect(router.input_bound).to be >= 512
      end

      it 'sums system + messages byte lengths + overhead' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        router = build_router(system: 'hello', messages: [{ role: :user, content: 'world' }])
        expect(router.input_bound).to eq('hello'.bytesize + 'world'.bytesize)
      end

      # ---------------------------------------------------------------
      # all-nil baseline (framing overhead zeroed)
      # ---------------------------------------------------------------

      it 'returns 0 when all content is nil/empty and overhead is 0' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        router = build_router(system: nil, messages: [])
        expect(router.input_bound).to eq(0)
      end

      it 'always returns an Integer' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        router = build_router(system: 'test', messages: [{ role: :user, content: 'hi' }])
        expect(router.input_bound).to be_a(Integer)
      end

      it 'always returns a non-negative Integer' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        router = build_router(system: nil, messages: [])
        expect(router.input_bound).to be >= 0
      end

      # ---------------------------------------------------------------
      # Multibyte UTF-8 byte counting (NOT char counting)
      # ---------------------------------------------------------------

      it 'counts euro sign (U+20AC) as 3 bytes, not 1 char' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        router = build_router(system: '€', messages: [])
        expect(router.input_bound).to eq(3)
        expect(router.input_bound).not_to eq(1)
      end

      it 'counts emoji (U+1F600) as 4 bytes, not 1 char' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        router = build_router(system: "\u{1F600}", messages: [])
        expect(router.input_bound).to eq(4)
        expect(router.input_bound).not_to eq(1)
      end

      it 'counts Japanese text by bytes: 日本語 = 9 bytes, not 3 chars' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        japanese = '日本語'
        router = build_router(messages: [{ role: :user, content: japanese }])
        expect(router.input_bound).to eq(9)
        expect(router.input_bound).not_to eq(3)
      end

      # ---------------------------------------------------------------
      # Content-block accounting
      # ---------------------------------------------------------------

      it 'counts text content blocks by byte length' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        messages = [{ role: :user, content: [{ type: :text, text: 'hi there' }] }]
        router = build_router(messages: messages)
        expect(router.input_bound).to eq('hi there'.bytesize)
      end

      it 'counts tool_use blocks as name.bytesize + JSON.dump(input).bytesize' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        messages = [
          { role: :assistant, content: [
            { type: :tool_use, id: 'tu_1', name: 'my_tool', input: { x: 1 } }
          ] }
        ]
        router = build_router(messages: messages)
        expected = 'my_tool'.bytesize + Legion::JSON.dump({ x: 1 }).bytesize
        expect(router.input_bound).to eq(expected)
      end

      it 'counts tool_result blocks by content byte length' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        messages = [
          { role: :user, content: [
            { type: :tool_result, tool_use_id: 'tu_1', text: 'the result string' }
          ] }
        ]
        router = build_router(messages: messages)
        expect(router.input_bound).to eq('the result string'.bytesize)
      end

      it 'counts image blocks as 0 bytes' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        messages = [
          { role: :user, content: [
            { type: :text, text: 'hello' },
            { type: :image, data: 'abc==', media_type: 'image/png', source_type: :base64 }
          ] }
        ]
        router = build_router(messages: messages)
        # Only text block contributes; image block is 0
        expect(router.input_bound).to eq('hello'.bytesize)
      end

      # ---------------------------------------------------------------
      # Structured inputs add serialized bytes
      # ---------------------------------------------------------------

      it 'adds tools serialized bytes when tools are provided' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        tools = [{ name: 'search', description: 'Search the web', input_schema: { type: 'object' } }]
        serialized = Legion::JSON.dump(tools).bytesize

        router_with    = build_router(tools: tools, messages: [])
        router_without = build_router(tools: nil, messages: [])
        expect(router_with.input_bound - router_without.input_bound).to eq(serialized)
      end

      it 'adds tool_choice serialized bytes when provided' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        tc = { mode: :tool, name: 'search' }
        serialized = Legion::JSON.dump(tc).bytesize

        router_with    = build_router(tool_choice: tc, messages: [])
        router_without = build_router(tool_choice: nil, messages: [])
        expect(router_with.input_bound - router_without.input_bound).to eq(serialized)
      end

      it 'adds thinking config serialized bytes when provided' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        thinking = { enabled: true, budget_tokens: 4096 }
        serialized = Legion::JSON.dump(thinking).bytesize

        router_with    = build_router(thinking: thinking, messages: [])
        router_without = build_router(thinking: nil, messages: [])
        expect(router_with.input_bound - router_without.input_bound).to eq(serialized)
      end

      it 'adds response_format serialized bytes when provided' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        rf = { type: :json_schema, schema: { name: 'result', type: 'object' } }
        serialized = Legion::JSON.dump(rf).bytesize

        router_with    = build_router(response_format: rf, messages: [])
        router_without = build_router(response_format: nil, messages: [])
        expect(router_with.input_bound - router_without.input_bound).to eq(serialized)
      end

      it 'adds request.extra serialized bytes when extra is nonempty' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        extra_payload = { temperature: 0.7, max_tokens: 1024 }
        serialized = Legion::JSON.dump(extra_payload).bytesize

        router_with    = build_router(extra: extra_payload, messages: [])
        router_without = build_router(extra: {}, messages: [])
        expect(router_with.input_bound - router_without.input_bound).to eq(serialized)
      end

      # ---------------------------------------------------------------
      # chars/4 heuristic is NOT used (byte counting, not token estimation)
      # ---------------------------------------------------------------

      it 'counts 1000 ASCII chars as ~1000 bytes, not ~250 (no chars/4 heuristic)' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        long_ascii = 'a' * 1000
        router = build_router(system: long_ascii, messages: [])
        expect(router.input_bound).to eq(1000)
        expect(router.input_bound).not_to eq(250)
      end

      # ---------------------------------------------------------------
      # Summation correctness: system + messages + tools + overhead
      # ---------------------------------------------------------------

      it 'sums system + messages + tools + overhead correctly' do
        system_text = 'You are helpful.'
        msg_text = 'What is 2+2?'
        tools = [{ name: 'calc', description: 'calculate', input_schema: {} }]
        overhead = 128

        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = overhead
        router = build_router(system: system_text, messages: [{ role: :user, content: msg_text }], tools: tools)
        expected = system_text.bytesize + msg_text.bytesize + Legion::JSON.dump(tools).bytesize + overhead
        expect(router.input_bound).to eq(expected)
      end

      # ---------------------------------------------------------------
      # Framing overhead offset behavior
      # ---------------------------------------------------------------

      it 'adds exact framing overhead from settings to the byte total' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 1024
        router = build_router(system: nil, messages: [])
        expect(router.input_bound).to eq(1024)
      end

      it 'accounts for framing overhead on top of content bytes' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 512
        router = build_router(system: 'test', messages: [])
        expect(router.input_bound).to eq('test'.bytesize + 512)
      end
    end

    context 'context_budget derivation' do
      it 'equals input_bound + required_output_tokens' do
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        router = build_router(system: 'x', messages: [], tokens: { max: 100 })
        expect(router.context_budget).to eq(router.input_bound + router.required_output_tokens)
        expect(router.required_output_tokens).to eq(100)
      end
    end
  end

  # ===========================================================================
  # next_lane — Selection and Rejection paths
  # ===========================================================================

  describe '#next_lane' do
    context 'with an eligible unconstrained request' do
      it 'returns a Selection when a ready lane exists' do
        activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
        router = build_router
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.model).to eq('gemma-12b')
        expect(result.provider_family).to eq(:vllm)
      end
    end

    context 'with an empty (cold) registry' do
      it 'returns a :too_early Rejection' do
        router = build_router
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:too_early)
        expect(result.http_status).to eq(425)
      end
    end

    context 'with a model pin that matches no lane' do
      it 'returns an :invalid_request Rejection (trusted pin stays hard)' do
        activate_lane(provider: :vllm, model: 'gemma-12b')
        router = build_router(routing: { model: 'nonexistent-model' })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:invalid_request)
        expect(result.http_status).to eq(400)
      end
    end

    context 'determinism' do
      it 'is deterministic for a fixed seed + generation' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b')
        activate_lane(provider: :vllm, instance_id: 'helios1', model: 'gemma-12b')
        router = build_router(seed: 'cd' * 16)
        a = router.next_lane
        # Build a fresh router with same seed (inventory is the same snapshot)
        router2 = build_router(seed: 'cd' * 16)
        b = router2.next_lane
        expect(a.lane_id).to eq(b.lane_id)
      end
    end

    context 'exclusion handling' do
      it 'excludes a consumed target and selects a different one' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b')
        activate_lane(provider: :vllm, instance_id: 'helios1', model: 'gemma-12b')
        router = build_router(routing: { model: 'gemma-12b' })
        first = router.next_lane
        expect(first).to be_a(Legion::Extensions::Llm::Routing::Selection)

        # Consume the first selection
        router.consume!(first)

        second = router.next_lane
        expect(second).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(second.attempt_target_key).not_to eq(first.attempt_target_key)
      end
    end

    context 'operation filter' do
      it 'rejects when no lane supports the requested operation' do
        activate_lane(provider: :vllm, model: 'gemma-12b', supported: %i[chat stream_chat])
        router = build_router(operation: :embed)
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      end

      it 'selects when a lane supports the operation' do
        activate_lane(provider: :vllm, model: 'gemma-12b', supported: %i[chat stream_chat embed],
                      capabilities: { streaming: :supported, embedding: :supported })
        router = build_router(operation: :embed)
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      end
    end

    # ------------------------------------------------------------------- #
    # Embed imposes NO context budget (regression: too_early from flat      #
    # framing budget). An embedding request carries no framed body — the    #
    # text is chunked POST-selection against the selected lane's own        #
    # context contract — so embed must route WITHOUT pre-proving a context  #
    # window. Before the fix @context_budget was input_framing_overhead +   #
    # tokens[:max] (nonzero), so an embed lane with UNKNOWN context evidence #
    # (vLLM max_model_len nil / Ollama num_ctx not yet enriched) evaluated   #
    # context_state :unknown and was rejected :too_early. Chat is unchanged: #
    # it still frames a body and requires KNOWN context evidence.            #
    # ------------------------------------------------------------------- #

    describe 'embed context budget (regression: too_early from flat framing budget)' do
      it 'evaluates context_state :not_applicable for an embed lane with UNKNOWN context evidence' do
        # context: nil → the offering publishes UNKNOWN context evidence.
        activate_lane(provider: :vllm, instance_id: 'primary', model: 'nomic-embed',
                      supported: %i[embed], capabilities: { embedding: :supported }, context: nil)
        router = build_router(operation: :embed)
        snap   = Legion::Extensions::Llm::Inventory::Registry.snapshot
        result = router.send(:evaluate_snapshot, snapshot: snap, model_pin: nil)

        embed_cand = result.candidates.first
        expect(embed_cand.context_state).to eq(:not_applicable)
        expect(embed_cand).to be_ready
        expect(result.ready_candidates.size).to eq(1)
      end

      it 'SELECTS the embed lane (not a :too_early Rejection) despite unknown context evidence' do
        activate_lane(provider: :vllm, instance_id: 'primary', model: 'nomic-embed',
                      supported: %i[embed], capabilities: { embedding: :supported }, context: nil)
        router = build_router(operation: :embed)
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.provider_family).to eq(:vllm)
        expect(result.model).to eq('nomic-embed')
      end

      it 'still requires KNOWN context evidence for :chat (unchanged) — unknown → context_state :unknown, :too_early' do
        # Same UNKNOWN context evidence, but a chat lane + chat request: chat
        # frames a body so the budget stays nonzero and context must be known.
        activate_lane(provider: :vllm, instance_id: 'primary', model: 'gemma-12b', context: nil)
        router = build_router(operation: :chat)
        snap   = Legion::Extensions::Llm::Inventory::Registry.snapshot
        result = router.send(:evaluate_snapshot, snapshot: snap, model_pin: nil)

        chat_cand = result.candidates.first
        expect(chat_cand.context_state).to eq(:unknown)
        expect(chat_cand).not_to be_ready

        rejection = router.next_lane
        expect(rejection).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(rejection.kind).to eq(:too_early)
        expect(rejection.http_status).to eq(425)
      end
    end

    # ------------------------------------------------------------------- #
    # Honored body-model hint fallback (v2 parity)                         #
    # ------------------------------------------------------------------- #

    describe 'honored body-model hint fallback' do
      around do |example|
        Legion::Settings[:llm][:router][:allow_body_routing_hints] = true
        example.run
      ensure
        Legion::Settings[:llm][:router][:allow_body_routing_hints] = false
      end

      it 'falls back to weighted selection when the honored hint matches no lane' do
        activate_lane(provider: :vllm, model: 'gemma-12b')
        router = build_router(client_model: 'no-such-model', body_model: 'no-such-model')
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.model).to eq('gemma-12b')
      end

      it 'pins the lane when the honored hint matches' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b')
        activate_lane(provider: :ollama, instance_id: 'local1', model: 'mistral7',
                      supported: %i[chat stream_chat])
        router = build_router(client_model: 'mistral7', body_model: 'mistral7')
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.model).to eq('mistral7')
      end

      it 'keeps trusted provider pins while falling back the hint' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b')
        activate_lane(provider: :ollama, instance_id: 'local1', model: 'gemma-12b',
                      supported: %i[chat stream_chat])
        router = build_router(
          client_model: 'no-such-model', body_model: 'no-such-model',
          routing: { provider: 'vllm' }
        )
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.provider_family).to eq(:vllm)
      end

      it 'returns :too_early on a cold catalog after the fallback' do
        router = build_router(client_model: 'no-such-model', body_model: 'no-such-model')
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:too_early)
      end

      it 'a trusted X-Legion-Model miss remains hard (no fallback)' do
        activate_lane(provider: :vllm, model: 'gemma-12b')
        # Trusted model pin from routing: hash; body hints enabled but irrelevant
        router = build_router(routing: { model: 'no-such-model' })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:invalid_request)
        expect(result.http_status).to eq(400)
      end

      it 'reports a tripped catalog as 503, not pin_nonexistent 400, after hint fallback' do
        token = activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
        SsotV3SnapshotFactory.mark_unavailable(
          provider_family: 'vllm', instance_id: 'primary',
          publisher_token_id: token.publisher_token_id
        )
        router = build_router(client_model: 'no-such-model', body_model: 'no-such-model')
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:service_unavailable)
        expect(result.http_status).to eq(503)
      end
    end

    # ------------------------------------------------------------------- #
    # Capability filtering                                                  #
    # ------------------------------------------------------------------- #

    describe 'capability-based selection' do
      it 'rejects when no lane attests the required capability (settled :unknown → 400)' do
        activate_lane(provider: :vllm, model: 'gemma-12b',
                      capabilities: { streaming: :supported, tools: :supported })
        # Request requires :thinking, which is absent → :unknown in evidence
        router = build_router(thinking: { enabled: true, budget_tokens: 1024 })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:invalid_request)
        expect(result.http_status).to eq(400)
      end

      it 'selects the lane that attests the required capability' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b',
                      capabilities: { streaming: :supported, tools: :supported })
        activate_lane(provider: :bedrock, instance_id: 'primary', model: 'gemma-12b',
                      tier: :cloud,
                      capabilities: { streaming: :supported, tools: :supported, thinking: :supported })
        router = build_router(thinking: { enabled: true, budget_tokens: 1024 })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.provider_family).to eq(:bedrock)
      end
    end

    # ------------------------------------------------------------------- #
    # Cross-provider model pin (N×N, no inferred provider)                  #
    # ------------------------------------------------------------------- #

    describe 'cross-provider model pin' do
      it 'selects the pinned model across providers without narrowing by provider' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b', context: 200_000)
        activate_lane(provider: :ollama, instance_id: 'local1', model: 'gemma-12b',
                      context: 200_000, supported: %i[chat stream_chat count_tokens])
        router = build_router(routing: { model: 'gemma-12b' })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.model).to eq('gemma-12b')
        expect(%i[vllm ollama]).to include(result.provider_family)
      end
    end

    # ------------------------------------------------------------------- #
    # Operator enable_* override routing                                    #
    # ------------------------------------------------------------------- #

    describe 'operator enable_* override routing' do
      it 'routes when the operator attests the capability via enable_* override' do
        activate_lane(provider: :vllm, instance_id: 'apollo', model: 'gemma-12b',
                      context: 200_000,
                      capabilities: { streaming: :supported, tools: :supported })
        # Operator enables thinking via per-instance config override
        Legion::Settings[:extensions][:llm][:vllm] = {
          instances: { 'apollo' => { enable_thinking: true, weight: 100 } }
        }
        router = build_router(thinking: { enabled: true, budget_tokens: 1024 })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.instance_id.to_s).to eq('apollo')
      end
    end

    # ------------------------------------------------------------------- #
    # Tripped + unknown evidence sibling → service_unavailable              #
    # ------------------------------------------------------------------- #

    describe 'tripped + unknown evidence sibling' do
      it 'reports tripped instance as 503 when another candidate has unknown capability evidence' do
        token = activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b',
                              context: 200_000,
                              capabilities: { streaming: :supported, tools: :supported })
        activate_lane(provider: :ollama, instance_id: 'local1', model: 'gemma-12b',
                      context: 200_000,
                      capabilities: { streaming: :supported, tools: :supported })
        SsotV3SnapshotFactory.mark_unavailable(
          provider_family: 'vllm', instance_id: 'h200',
          publisher_token_id: token.publisher_token_id
        )
        # Request requires :thinking, which neither instance declares (unknown evidence)
        # but vllm is also tripped — 503 takes priority over unknown
        router = build_router(thinking: { enabled: true, budget_tokens: 1024 })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:service_unavailable)
        expect(result.http_status).to eq(503)
      end
    end

    # ------------------------------------------------------------------- #
    # Tier constraint selection                                              #
    # ------------------------------------------------------------------- #

    describe 'tier constraint' do
      it 'selects only the matching-tier offering when tier is pinned' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b',
                      tier: :local, context: 200_000)
        activate_lane(provider: :bedrock, instance_id: 'cloud1', model: 'claude-sonnet',
                      tier: :cloud, context: 200_000)
        router = build_router(routing: { tier: 'local' })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.provider_family).to eq(:vllm)
      end

      it 'returns a Rejection when the tier constraint excludes all available offerings' do
        activate_lane(provider: :vllm, model: 'gemma-12b', tier: :local, context: 200_000)
        router = build_router(routing: { tier: 'cloud' })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      end
    end

    # ------------------------------------------------------------------- #
    # Provider pin miss                                                     #
    # ------------------------------------------------------------------- #

    describe 'provider pin miss' do
      it 'returns a Rejection when the pinned provider has no offerings' do
        activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
        router = build_router(routing: { provider: 'bedrock' })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      end
    end

    # ------------------------------------------------------------------- #
    # Instance pin select                                                   #
    # ------------------------------------------------------------------- #

    describe 'instance pin' do
      it 'selects only the pinned instance' do
        activate_lane(provider: :vllm, instance_id: 'apollo', model: 'gemma-12b', context: 200_000)
        activate_lane(provider: :vllm, instance_id: 'hermes', model: 'gemma-12b', context: 200_000)
        router = build_router(routing: { instance: 'apollo' })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.instance_id.to_s).to eq('apollo')
      end
    end

    # ------------------------------------------------------------------- #
    # Capability alias normalization                                         #
    # ------------------------------------------------------------------- #

    describe 'capability alias normalization' do
      it 'selects offering declaring :function_calling when :tools is required' do
        # Offering declares the alias :function_calling; request derives :tools from tools array
        SsotV3SnapshotFactory.activate(
          provider_family: 'openai', instance_id: 'primary',
          callable: SsotV3SnapshotFactory::FactoryCallable.new,
          drafts: [SsotV3SnapshotFactory.offering_draft(
            model: 'gpt-5', tier: :frontier, context: 200_000,
            supported: %i[chat stream_chat count_tokens],
            capabilities: { function_calling: :supported, streaming: :supported }
          )]
        )
        router = build_router(tools: [{ name: 'search', description: 'Search the web' }])
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.provider_family).to eq(:openai)
      end

      it 'selects offering declaring :tool_use when :tools is required' do
        SsotV3SnapshotFactory.activate(
          provider_family: 'anthropic', instance_id: 'cloud1',
          callable: SsotV3SnapshotFactory::FactoryCallable.new,
          drafts: [SsotV3SnapshotFactory.offering_draft(
            model: 'claude-sonnet', tier: :frontier, context: 200_000,
            supported: %i[chat stream_chat count_tokens],
            capabilities: { tool_use: :supported, streaming: :supported }
          )]
        )
        router = build_router(tools: [{ name: 'search', description: 'Search the web' }])
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.provider_family).to eq(:anthropic)
      end
    end

    # ------------------------------------------------------------------- #
    # Cross-tier exclusion fallback                                          #
    # ------------------------------------------------------------------- #

    describe 'cross-tier exclusion fallback' do
      it 'falls back to a different tier/provider when the first selection is excluded' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b',
                      tier: :local, context: 200_000)
        activate_lane(provider: :bedrock, instance_id: 'cloud1', model: 'claude-sonnet',
                      tier: :cloud, context: 200_000)
        router = build_router
        first = router.next_lane
        expect(first).to be_a(Legion::Extensions::Llm::Routing::Selection)
        router.consume!(first)
        second = router.next_lane
        expect(second).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(second.instance_id.to_s).not_to eq(first.instance_id.to_s)
      end
    end

    # ------------------------------------------------------------------- #
    # 3-tier isolation                                                       #
    # ------------------------------------------------------------------- #

    describe '3-tier isolation' do
      it 'tier pin :local isolates among local/cloud/frontier offerings' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b',
                      tier: :local, context: 200_000)
        activate_lane(provider: :bedrock, instance_id: 'cloud1', model: 'claude-sonnet',
                      tier: :cloud, context: 200_000)
        activate_lane(provider: :anthropic, instance_id: 'frontier1', model: 'claude-opus',
                      tier: :frontier, context: 200_000)
        router = build_router(routing: { tier: 'local' })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(result.provider_family).to eq(:vllm)
      end
    end

    # ------------------------------------------------------------------- #
    # No hail-mary G24 (no implicit default bypass)                         #
    # ------------------------------------------------------------------- #

    describe 'no hail-mary G24' do
      it 'returns a Rejection when provider pin excludes all lanes, even with default_provider configured' do
        Legion::Settings.loader.settings[:llm][:default_provider] = :openai
        Legion::Settings.loader.settings[:llm][:default_model]    = 'gpt-5'
        activate_lane(provider: :openai, instance_id: 'primary', model: 'gpt-5',
                      tier: :frontier, context: 200_000)
        router = build_router(routing: { provider: 'bedrock' })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      end

      it 'configured default_provider is not a bypass — filters still apply' do
        Legion::Settings.loader.settings[:llm][:default_provider] = :anthropic
        Legion::Settings.loader.settings[:llm][:default_model]    = 'claude-sonnet'
        activate_lane(provider: :anthropic, instance_id: 'primary', model: 'claude-sonnet',
                      tier: :frontier, context: 200_000)
        router = build_router(routing: { provider: 'bedrock' })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      end
    end

    # ------------------------------------------------------------------- #
    # Seed distribution (determinism G25)                                    #
    # ------------------------------------------------------------------- #

    describe 'seed distribution' do
      it 'distributes selections across instances for varied seeds (>1 distinct instance over 30 seeds)' do
        activate_lane(provider: :vllm, instance_id: 'i0', model: 'gemma-12b', context: 200_000)
        activate_lane(provider: :vllm, instance_id: 'i1', model: 'gemma-12b', context: 200_000)
        activate_lane(provider: :vllm, instance_id: 'i2', model: 'gemma-12b', context: 200_000)
        results = 30.times.map do |i|
          seed = i.to_s(16).rjust(2, '0') * 16
          r = build_router(seed: seed, routing: { model: 'gemma-12b' })
          r.next_lane
        end
        expect(results).to all(be_a(Legion::Extensions::Llm::Routing::Selection))
        expect(results.map { |s| s.instance_id.to_s }.uniq.size).to be > 1
      end
    end
  end

  # ===========================================================================
  # next_attempt — attempt state management
  # ===========================================================================

  describe '#next_attempt' do
    context 'with available lanes' do
      it 'returns an AttemptContext on first call' do
        activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
        router = build_router
        result = router.next_attempt
        expect(result).to be_a(Legion::LLM::Inference::AttemptContext)
        expect(result.attempt_number).to eq(1)
      end

      it 'increments attempt count on each call' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b', context: 200_000)
        activate_lane(provider: :vllm, instance_id: 'helios1', model: 'gemma-12b', context: 200_000)
        activate_lane(provider: :vllm, instance_id: 'helios2', model: 'gemma-12b', context: 200_000)
        router = build_router(routing: { model: 'gemma-12b' })
        first = router.next_attempt
        second = router.next_attempt
        expect(first.attempt_number).to eq(1)
        expect(second.attempt_number).to eq(2)
      end

      it 'consumes targets: subsequent calls get different lanes' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b', context: 200_000)
        activate_lane(provider: :vllm, instance_id: 'helios1', model: 'gemma-12b', context: 200_000)
        router = build_router(routing: { model: 'gemma-12b' })
        first = router.next_attempt
        second = router.next_attempt
        expect(first.selection.attempt_target_key).not_to eq(second.selection.attempt_target_key)
      end
    end

    context 'with attempts exhausted' do
      it 'returns an attempts_exhausted Rejection (503) when budget is spent' do
        Legion::Settings[:llm][:router][:max_attempts] = 1
        activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
        router = build_router
        router.next_attempt # uses the 1 allowed attempt
        result = router.next_attempt
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:attempts_exhausted)
        expect(result.http_status).to eq(503)
      end
    end

    context 'with no lanes available' do
      it 'returns a Rejection when the registry is cold' do
        router = build_router
        result = router.next_attempt
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:too_early)
      end
    end
  end

  # ===========================================================================
  # next_attempt! — raises on Rejection
  # ===========================================================================

  describe '#next_attempt!' do
    it 'returns an AttemptContext on success' do
      activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
      router = build_router
      expect(router.next_attempt!).to be_a(Legion::LLM::Inference::AttemptContext)
    end

    it 'raises Errors::RoutingRejected on a Rejection' do
      router = build_router
      expect { router.next_attempt! }.to raise_error(Legion::LLM::Errors::RoutingRejected) do |err|
        expect(err.rejection).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      end
    end
  end

  # ===========================================================================
  # classify — outcome classification
  # ===========================================================================

  describe '#classify' do
    let(:router) do
      activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b', context: 200_000)
      activate_lane(provider: :vllm, instance_id: 'helios1', model: 'gemma-12b', context: 200_000)
      build_router(routing: { model: 'gemma-12b' })
    end

    let(:attempt) { router.next_attempt }

    context 'success outcome' do
      it 'returns a :success Action' do
        result = dispatch_result(kind: :success)
        action = router.classify(dispatch_result: result, attempt_context: attempt)
        expect(action.disposition).to eq(:success)
        expect(action.exclusions).to be_empty
      end
    end

    context 'retryable outcome (provider_error)' do
      it 'returns a :retry Action with exclusions' do
        result = dispatch_result(kind: :provider_error, reason: 'upstream 500')
        action = router.classify(dispatch_result: result, attempt_context: attempt)
        expect(action.disposition).to eq(:retry)
      end
    end

    context 'instance_unavailable outcome' do
      it 'returns a :retry Action with a global_transition' do
        result = dispatch_result(kind: :instance_unavailable, reason: 'health check failed')
        action = router.classify(dispatch_result: result, attempt_context: attempt)
        expect(action.disposition).to eq(:retry)
        expect(action.global_transition).not_to be_nil
        expect(action.global_transition.kind).to eq(:instance_unavailable)
      end
    end

    context 'terminal outcome (policy)' do
      it 'returns a :terminal Action with a rejection' do
        result = dispatch_result(kind: :policy, reason: 'org policy violation')
        action = router.classify(dispatch_result: result, attempt_context: attempt)
        expect(action.disposition).to eq(:terminal)
        expect(action.rejection).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(action.rejection.kind).to eq(:policy_denied)
      end
    end

    context 'exclusion accumulation' do
      it 'adds exclusions from the action to the router state' do
        # Make a retryable outcome (which may add quota exclusions)
        result = dispatch_result(kind: :provider_error, reason: 'timeout')
        initial_count = router.exclusions.size
        router.classify(dispatch_result: result, attempt_context: attempt)
        # At minimum the consume! exclusion was already added by next_attempt;
        # classify may add more if the outcome has quota domains.
        expect(router.exclusions.size).to be >= initial_count
      end
    end
  end

  # ===========================================================================
  # add_exclusion
  # ===========================================================================

  describe '#add_exclusion' do
    it 'appends the exclusion to the exclusion list' do
      activate_lane(provider: :vllm, model: 'gemma-12b')
      router = build_router
      exclusion = Legion::Extensions::Llm::Routing::Exclusion.new(
        target_kind: :attempt_target,
        target: Legion::Extensions::Llm::Routing::AttemptTargetKey.new(
          provider_family: :vllm, instance_id: 'primary', model: 'gemma-12b'
        ),
        reason: 'test_exclusion', evidence: {}, lifetime: :request
      )
      router.add_exclusion(exclusion: exclusion)
      expect(router.exclusions).to include(exclusion)
    end
  end

  # ===========================================================================
  # consume!
  # ===========================================================================

  describe '#consume!' do
    it 'records the target as consumed and increments attempts' do
      activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
      router = build_router
      selection = router.next_lane
      expect(selection).to be_a(Legion::Extensions::Llm::Routing::Selection)

      expect(router.attempts_remaining).to eq(router.maximum_attempts)
      router.consume!(selection)
      expect(router.attempts_remaining).to eq(router.maximum_attempts - 1)
      expect(router.consumed_targets).to include(selection.attempt_target_key)
    end
  end

  # ===========================================================================
  # attempts_remaining
  # ===========================================================================

  describe '#attempts_remaining' do
    it 'decrements as attempts are consumed' do
      Legion::Settings[:llm][:router][:max_attempts] = 3
      activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b', context: 200_000)
      activate_lane(provider: :vllm, instance_id: 'helios1', model: 'gemma-12b', context: 200_000)
      activate_lane(provider: :vllm, instance_id: 'helios2', model: 'gemma-12b', context: 200_000)
      router = build_router(routing: { model: 'gemma-12b' })
      expect(router.attempts_remaining).to eq(3)
      router.next_attempt
      expect(router.attempts_remaining).to eq(2)
      router.next_attempt
      expect(router.attempts_remaining).to eq(1)
      router.next_attempt
      expect(router.attempts_remaining).to eq(0)
    end

    it 'never goes negative' do
      Legion::Settings[:llm][:router][:max_attempts] = 1
      activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
      router = build_router
      router.next_attempt
      expect(router.attempts_remaining).to eq(0)
    end
  end

  # ===========================================================================
  # rejection?
  # ===========================================================================

  describe '#rejection?' do
    it 'returns true for a Routing::Rejection' do
      router = build_router
      rejection = Legion::Extensions::Llm::Routing::Rejection.new(
        kind: :too_early, reason: 'test', inventory_generation: 0,
        candidate_counts: {}, http_status: 425
      )
      expect(router.rejection?(rejection)).to be true
    end

    it 'returns false for a Selection' do
      activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
      router = build_router
      selection = router.next_lane
      expect(router.rejection?(selection)).to be false
    end

    it 'returns false for nil' do
      router = build_router
      expect(router.rejection?(nil)).to be false
    end
  end

  # ===========================================================================
  # Class-level status queries
  # ===========================================================================

  describe '.routing_enabled?' do
    it 'returns false when the Registry has no complete publications' do
      expect(described_class.routing_enabled?).to be false
    end

    it 'returns false for an initializing (unactivated) claim' do
      SsotV3SnapshotFactory.claim_only(provider_family: :vllm, instance_id: 'primary')
      expect(described_class.routing_enabled?).to be false
    end

    it 'returns true once an instance has a complete publication' do
      activate_lane(provider: :vllm, model: 'gemma-12b')
      expect(described_class.routing_enabled?).to be true
    end
  end

  describe '.tier_priority' do
    it 'returns the configured tier priority as Symbols' do
      Legion::Settings[:llm][:router][:tier_priority] = %w[local direct cloud]
      result = described_class.tier_priority
      expect(result).to eq(%i[local direct cloud])
    end

    it 'returns the default when not overridden' do
      result = described_class.tier_priority
      expect(result).to include(:local)
      expect(result).to all(be_a(Symbol))
    end
  end

  describe '.tier_available?' do
    before do
      allow(described_class).to receive(:privacy_mode?).and_return(false)
    end

    it 'returns true for :local' do
      expect(described_class.tier_available?(:local)).to be true
    end

    it 'returns true for :direct' do
      expect(described_class.tier_available?(:direct)).to be true
    end

    context 'when privacy mode is on' do
      before { allow(described_class).to receive(:privacy_mode?).and_return(true) }

      it 'returns false for :cloud' do
        expect(described_class.tier_available?(:cloud)).to be false
      end

      it 'returns false for :frontier' do
        expect(described_class.tier_available?(:frontier)).to be false
      end

      it 'returns true for :local (non-external tier)' do
        expect(described_class.tier_available?(:local)).to be true
      end
    end

    context ':fleet tier' do
      it 'returns true when Legion::Transport is defined' do
        stub_const('Legion::Transport', Module.new)
        expect(described_class.tier_available?(:fleet)).to be true
      end

      it 'returns false when Legion::Transport is not defined' do
        hide_const('Legion::Transport') if defined?(Legion::Transport)
        expect(described_class.tier_available?(:fleet)).to be false
      end
    end
  end

  describe '.privacy_mode?' do
    it 'delegates to Legion::Settings.enterprise_privacy?' do
      allow(Legion::Settings).to receive(:enterprise_privacy?).and_return(true)
      expect(described_class.privacy_mode?).to be true
    end

    it 'returns false when enterprise_privacy? is false' do
      allow(Legion::Settings).to receive(:enterprise_privacy?).and_return(false)
      expect(described_class.privacy_mode?).to be false
    end
  end

  # ===========================================================================
  # Rejection diagnostics (exercised via next_lane)
  # ===========================================================================

  describe 'rejection diagnostics via next_lane' do
    context 'policy_denied (all lanes policy-denied)' do
      it 'returns :policy_denied 403' do
        activate_lane(provider: :vllm, model: 'gemma-12b')
        # Blacklist the only available model
        Legion::Settings[:extensions][:llm][:vllm] = {
          instances: { 'primary' => { model_blacklist: ['gemma-12b'] } }
        }
        router = build_router
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:policy_denied)
        expect(result.http_status).to eq(403)
      end
    end

    context 'failed_dependency (all lanes unsupported operation, complete scope)' do
      it 'returns :failed_dependency 424' do
        # Only supports chat, not embed; no unknown evidence
        activate_lane(provider: :vllm, model: 'gemma-12b',
                      supported: %i[chat stream_chat],
                      capabilities: { streaming: :supported })
        router = build_router(operation: :embed)
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:failed_dependency)
        expect(result.http_status).to eq(424)
      end
    end

    context 'service_unavailable (all eligible instances tripped)' do
      it 'returns :service_unavailable 503' do
        token = activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
        SsotV3SnapshotFactory.mark_unavailable(
          provider_family: 'vllm', instance_id: 'primary',
          publisher_token_id: token.publisher_token_id
        )
        router = build_router
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:service_unavailable)
        expect(result.http_status).to eq(503)
      end
    end

    context 'context_rejected (all lanes fail context constraint)' do
      it 'returns :context_rejected 400' do
        # Lane has context window of 100 tokens; request needs much more
        activate_lane(provider: :vllm, model: 'gemma-12b', context: 100)
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        # A large system prompt to exceed the tiny context window
        big_system = 'x' * 200
        router = build_router(system: big_system, tokens: { max: 100 })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:context_rejected)
        expect(result.http_status).to eq(400)
      end
    end

    context 'weight_state :disabled → policy_denied' do
      it 'returns :policy_denied 403 when all lanes have zeroed weight' do
        SsotV3SnapshotFactory.activate(
          provider_family: 'vllm', instance_id: 'primary',
          callable: SsotV3SnapshotFactory::FactoryCallable.new,
          drafts: [SsotV3SnapshotFactory.offering_draft(
            model: 'gemma-12b', tier: :local, context: 200_000,
            supported: %i[chat stream_chat count_tokens],
            capabilities: { streaming: :supported },
            # A zeroed weight: base_weight must equal the product of weight_inputs
            # (records.rb validates the pair together), so one input is 0.
            weight_inputs: { tier: 0, provider: 1, instance: 1, model_or_offering: 1 },
            base_weight:   0
          )]
        )
        router = build_router
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:policy_denied)
        expect(result.http_status).to eq(403)
      end
    end

    context 'capability_state :unsupported (authoritative) → failed_dependency' do
      it 'returns :failed_dependency 424, distinct from settled-unknown 400' do
        # Offering authoritatively declares thinking as :unsupported
        SsotV3SnapshotFactory.activate(
          provider_family: 'vllm', instance_id: 'primary',
          callable: SsotV3SnapshotFactory::FactoryCallable.new,
          drafts: [SsotV3SnapshotFactory.offering_draft(
            model: 'gemma-12b', tier: :local, context: 200_000,
            supported: %i[chat stream_chat count_tokens],
            capabilities: { streaming: :supported, tools: :supported, thinking: :unsupported }
          )]
        )
        router = build_router(thinking: { enabled: true, budget_tokens: 1024 })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:failed_dependency)
        expect(result.http_status).to eq(424)
      end
    end

    context 'tripped + unknown capability → service_unavailable 503' do
      it 'tripped-fit candidate + unknown-capability sibling → 503' do
        # First instance: fits on all axes, but tripped
        token = activate_lane(provider: :vllm, instance_id: 'apollo', model: 'gemma-12b',
                              context: 200_000,
                              capabilities: { streaming: :supported, tools: :supported,
                                              thinking: :supported })
        # Second instance: thinking is unknown (absent from capabilities)
        activate_lane(provider: :ollama, instance_id: 'local1', model: 'gemma-12b',
                      context: 200_000,
                      capabilities: { streaming: :supported, tools: :supported })
        SsotV3SnapshotFactory.mark_unavailable(
          provider_family: 'vllm', instance_id: 'apollo',
          publisher_token_id: token.publisher_token_id
        )
        router = build_router(thinking: { enabled: true, budget_tokens: 1024 })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:service_unavailable)
        expect(result.http_status).to eq(503)
      end

      it 'tripped-not-fit candidate + unknown-capability sibling → 503' do
        # First instance: thinking unsupported AND tripped
        token = SsotV3SnapshotFactory.activate(
          provider_family: 'vllm', instance_id: 'apollo',
          callable: SsotV3SnapshotFactory::FactoryCallable.new,
          drafts: [SsotV3SnapshotFactory.offering_draft(
            model: 'gemma-12b', tier: :local, context: 200_000,
            supported: %i[chat stream_chat count_tokens],
            capabilities: { streaming: :supported, thinking: :unsupported }
          )]
        )
        # Second instance: thinking is unknown
        activate_lane(provider: :ollama, instance_id: 'local1', model: 'gemma-12b',
                      context: 200_000,
                      capabilities: { streaming: :supported, tools: :supported })
        SsotV3SnapshotFactory.mark_unavailable(
          provider_family: 'vllm', instance_id: 'apollo',
          publisher_token_id: token.publisher_token_id
        )
        router = build_router(thinking: { enabled: true, budget_tokens: 1024 })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:service_unavailable)
        expect(result.http_status).to eq(503)
      end
    end

    context 'tripped skipped when fit+available-but-consumed candidate exists' do
      it 'falls to catch-all :service_unavailable 503' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b', context: 200_000)
        token = activate_lane(provider: :vllm, instance_id: 'helios1', model: 'gemma-12b',
                              context: 200_000)
        SsotV3SnapshotFactory.mark_unavailable(
          provider_family: 'vllm', instance_id: 'helios1',
          publisher_token_id: token.publisher_token_id
        )
        router = build_router(routing: { model: 'gemma-12b' })
        # Consume the only available instance
        first = router.next_lane
        expect(first).to be_a(Legion::Extensions::Llm::Routing::Selection)
        router.consume!(first)
        # Now: h200 is consumed (excluded), helios1 is tripped
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:service_unavailable)
        expect(result.http_status).to eq(503)
      end
    end

    context 'initializing scope + no candidates → too_early' do
      it 'returns :too_early 425 when only an initializing scope exists' do
        SsotV3SnapshotFactory.claim_only(provider_family: 'vllm', instance_id: 'h200')
        router = build_router
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:too_early)
        expect(result.http_status).to eq(425)
      end
    end

    context 'initializing/mixed scope + unknown capability → too_early' do
      it 'initializing scope with unknown capability → :too_early 425' do
        # Activate one instance (complete scope) that has unknown thinking evidence
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b',
                      context: 200_000,
                      capabilities: { streaming: :supported, tools: :supported })
        # Add an initializing scope (claim without activation)
        SsotV3SnapshotFactory.claim_only(provider_family: 'ollama', instance_id: 'helios1')
        # The presence of an initializing scope means evidence is not settled →
        # :too_early rather than :invalid_request
        router = build_router(thinking: { enabled: true, budget_tokens: 1024 })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:too_early)
        expect(result.http_status).to eq(425)
      end
    end

    context 'mixed available + unavailable (no unknowns) → service_unavailable' do
      it 'returns :service_unavailable 503 when some instances are tripped and the rest are consumed' do
        activate_lane(provider: :vllm, instance_id: 'h200', model: 'gemma-12b', context: 200_000)
        token = activate_lane(provider: :vllm, instance_id: 'helios1', model: 'gemma-12b',
                              context: 200_000)
        SsotV3SnapshotFactory.mark_unavailable(
          provider_family: 'vllm', instance_id: 'helios1',
          publisher_token_id: token.publisher_token_id
        )
        router = build_router(routing: { model: 'gemma-12b' })
        # Consume h200 (available)
        first = router.next_lane
        expect(first).to be_a(Legion::Extensions::Llm::Routing::Selection)
        expect(first.instance_id.to_s).to eq('h200')
        router.consume!(first)
        # helios1 is tripped, h200 is consumed → service_unavailable
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:service_unavailable)
        expect(result.http_status).to eq(503)
      end
    end

    context 'dimension_state :rejected → context_rejected' do
      it 'returns :context_rejected 400 when all offerings have insufficient context' do
        # Two lanes, both with small context windows
        SsotV3SnapshotFactory.activate(
          provider_family: 'vllm', instance_id: 'small1',
          callable: SsotV3SnapshotFactory::FactoryCallable.new,
          drafts: [SsotV3SnapshotFactory.offering_draft(
            model: 'tiny-model', tier: :local, context: 50,
            supported: %i[chat stream_chat count_tokens],
            capabilities: { streaming: :supported }
          )]
        )
        SsotV3SnapshotFactory.activate(
          provider_family: 'ollama', instance_id: 'small2',
          callable: SsotV3SnapshotFactory::FactoryCallable.new,
          drafts: [SsotV3SnapshotFactory.offering_draft(
            model: 'tiny-model-2', tier: :local, context: 50,
            supported: %i[chat stream_chat count_tokens],
            capabilities: { streaming: :supported }
          )]
        )
        Legion::Settings[:llm][:router][:input_framing_overhead_tokens] = 0
        router = build_router(system: 'x' * 200, tokens: { max: 100 })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:context_rejected)
        expect(result.http_status).to eq(400)
      end
    end

    context 'candidate_counts metadata' do
      it 'carries per-axis candidate_counts on the Rejection' do
        activate_lane(provider: :vllm, model: 'gemma-12b',
                      capabilities: { streaming: :supported, tools: :supported })
        # Require :thinking which is absent → rejection
        router = build_router(thinking: { enabled: true, budget_tokens: 1024 })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.candidate_counts).to be_a(Hash)
        expect(result.candidate_counts).not_to be_empty
      end
    end

    # ------------------------------------------------------------------- #
    # Puma-8 regression: BINARY-encoded model pin normalized to UTF-8       #
    # ------------------------------------------------------------------- #
    # NOTE: In the SSOT v3 architecture, BINARY normalization happens at
    # the trust boundary (HeaderConstraints.from_internal) when
    # Request.build_for_test is called. The Router always receives valid
    # UTF-8 pins. We verify the end-to-end path: a BINARY pin passed via
    # the routing hash produces a typed :invalid_request 400 (not 500)
    # and the Rejection's explicit_pins contain valid UTF-8.

    context 'Puma-8 regression: BINARY model pin → typed 400' do
      it 'returns typed :invalid_request 400 with UTF-8 explicit_pins, not untyped 500' do
        activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
        # Simulate Puma 8 delivering an ASCII-8BIT header value
        binary_pin = 'us.anthropic.claude-sonnet-4-6'.b
        expect(binary_pin.encoding).to eq(Encoding::ASCII_8BIT)
        router = build_router(routing: { model: binary_pin })
        result = router.next_lane
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:invalid_request)
        expect(result.http_status).to eq(400)
        # The pin must be normalized to UTF-8 in the rejection record
        expect(result.explicit_pins[:model].encoding).to eq(Encoding::UTF_8) if result.respond_to?(:explicit_pins) && result.explicit_pins[:model]
      end
    end
  end

  # ===========================================================================
  # stale_selection and attempts_exhausted
  # ===========================================================================

  describe '#attempts_exhausted' do
    it 'returns a :attempts_exhausted Rejection with 503' do
      activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
      router = build_router
      snap = Legion::Extensions::Llm::Inventory::Registry.snapshot
      result = router.attempts_exhausted(snap)
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      expect(result.kind).to eq(:attempts_exhausted)
      expect(result.http_status).to eq(503)
      expect(result.inventory_generation).to eq(snap.generation)
    end
  end

  describe '#stale_selection' do
    it 'returns a :stale_selection Rejection' do
      activate_lane(provider: :vllm, model: 'gemma-12b', context: 200_000)
      router = build_router
      snap = Legion::Extensions::Llm::Inventory::Registry.snapshot
      result = router.stale_selection(snap)
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
      expect(result.kind).to eq(:stale_selection)
    end
  end

  # ===========================================================================
  # TIER_EXTERNAL constant
  # ===========================================================================

  describe 'TIER_EXTERNAL' do
    it 'contains :cloud and :frontier as frozen' do
      expect(described_class::TIER_EXTERNAL).to include(:cloud, :frontier)
      expect(described_class::TIER_EXTERNAL).to be_frozen
    end

    it 'does not contain :local or :direct' do
      expect(described_class::TIER_EXTERNAL).not_to include(:local)
      expect(described_class::TIER_EXTERNAL).not_to include(:direct)
    end
  end

  # ===========================================================================
  # #evaluate_snapshot (orchestration) — reproduced from candidate_evaluator_spec
  # ===========================================================================

  describe '#evaluate_snapshot (orchestration)' do
    # N×N: same model on two instances → two independent candidates
    context 'N×N: same model on two instances' do
      before do
        activate_lane(provider: :vllm, instance_id: 'helios1', model: 'gemma-12b')
        activate_lane(provider: :vllm, instance_id: 'helios2', model: 'gemma-12b')
      end

      it 'returns an EvaluationSet with 2 candidates, both ready' do
        router = build_router
        snap   = Legion::Extensions::Llm::Inventory::Registry.snapshot
        result = router.send(:evaluate_snapshot, snapshot: snap, model_pin: nil)

        expect(result).to be_a(Legion::LLM::Routing::EvaluationSet)
        expect(result.candidates.size).to eq(2)

        instance_ids = result.candidates.map { |c| c.lane.instance_key.instance_id }.sort
        expect(instance_ids).to eq(%w[helios1 helios2])
      end

      it 'makes both candidates independently ready' do
        router = build_router
        snap   = Legion::Extensions::Llm::Inventory::Registry.snapshot
        result = router.send(:evaluate_snapshot, snapshot: snap, model_pin: nil)

        expect(result.ready_candidates.size).to eq(2)
      end
    end

    # N×N targeted exclusion: excluding one instance leaves only the other
    context 'N×N targeted exclusion' do
      before do
        activate_lane(provider: :vllm, instance_id: 'helios1', model: 'gemma-12b')
        activate_lane(provider: :vllm, instance_id: 'helios2', model: 'gemma-12b')
      end

      it 'excludes only the targeted instance; ready_candidates drops to 1' do
        router = build_router
        exclusion = Legion::Extensions::Llm::Routing::Exclusion.new(
          target_kind: :attempt_target,
          target:      Legion::Extensions::Llm::Routing::AttemptTargetKey.new(
            provider_family: :vllm, instance_id: 'helios1', model: 'gemma-12b'
          ),
          reason:      'attempt_consumed',
          evidence:    { attempt_number: 1 },
          lifetime:    :request
        )
        router.add_exclusion(exclusion: exclusion)

        snap   = Legion::Extensions::Llm::Inventory::Registry.snapshot
        result = router.send(:evaluate_snapshot, snapshot: snap, model_pin: nil)

        helios1 = result.candidates.find { |c| c.lane.instance_key.instance_id == 'helios1' }
        helios2 = result.candidates.find { |c| c.lane.instance_key.instance_id == 'helios2' }

        expect(helios1.exclusion_state).to eq(:excluded)
        expect(helios2.exclusion_state).to eq(:clear)
        expect(result.ready_candidates.size).to eq(1)
        expect(result.ready_candidates.first.lane.instance_key.instance_id).to eq('helios2')
      end
    end

    # Initializing claim: claimed-but-not-activated scope appears only in
    # publication_statuses with state :initializing, never as a candidate.
    context 'initializing claim handling' do
      before do
        SsotV3SnapshotFactory.claim_only(provider_family: 'vllm', instance_id: 'h200')
        activate_lane(provider: :vllm, instance_id: 'helios1', model: 'gemma-12b')
      end

      it 'includes the initializing scope in publication_statuses with state :initializing' do
        router = build_router
        snap   = Legion::Extensions::Llm::Inventory::Registry.snapshot
        result = router.send(:evaluate_snapshot, snapshot: snap, model_pin: nil)

        init_key = SsotV3SnapshotFactory.instance_key(provider_family: 'vllm', instance_id: 'h200')
        init_ps  = result.publication_statuses.find { |ps| ps.instance_key == init_key }

        expect(init_ps).not_to be_nil
        expect(init_ps.state).to eq(:initializing)
      end

      it 'does not include the initializing scope as a candidate' do
        router = build_router
        snap   = Legion::Extensions::Llm::Inventory::Registry.snapshot
        result = router.send(:evaluate_snapshot, snapshot: snap, model_pin: nil)

        expect(result.candidates.size).to eq(1)
        expect(result.candidates.first.lane.instance_key.instance_id).to eq('helios1')
      end
    end

    # Empty snapshot: evaluate_snapshot on an empty registry
    context 'empty snapshot' do
      it 'returns an EvaluationSet with empty candidates and empty publication_statuses' do
        router = build_router
        snap   = Legion::Extensions::Llm::Inventory::Registry.snapshot
        result = router.send(:evaluate_snapshot, snapshot: snap, model_pin: nil)

        expect(result.candidates).to be_empty
        expect(result.publication_statuses).to be_empty
      end
    end

    # inventory_generation: EvaluationSet carries the snapshot generation
    context 'inventory_generation' do
      it 'returns EvaluationSet with inventory_generation == snapshot.generation' do
        activate_lane(provider: :vllm, model: 'gemma-12b')
        router = build_router
        snap   = Legion::Extensions::Llm::Inventory::Registry.snapshot
        result = router.send(:evaluate_snapshot, snapshot: snap, model_pin: nil)

        expect(result.inventory_generation).to eq(snap.generation)
      end
    end
  end

  # ===========================================================================
  # reject_no_candidates — direct unit tests with synthetic EvaluationSets
  #
  # These scenarios involve :unknown axis states that the ssot_v3 factory cannot
  # produce end-to-end (it only yields authoritative evidence). We exercise the
  # Router's private reject_no_candidates directly with hand-constructed
  # CandidateEvaluation objects to verify the rejection triage logic.
  # ===========================================================================

  describe 'reject_no_candidates (synthetic evaluation sets)' do
    # Build a synthetic CandidateEvaluation with all-green defaults; override axes.
    def synth_candidate(**axes)
      defaults = {
        lane:                 stub_lane,
        operation_state:      :supported,
        pin_state:            :match,
        policy_state:         :allowed,
        capability_state:     :supported,
        context_state:        :not_applicable,
        dimension_state:      :not_applicable,
        availability_state:   :available,
        exclusion_state:      :clear,
        fleet_contract_state: :not_applicable,
        weight_state:         :enabled
      }
      Legion::LLM::Routing::CandidateEvaluation.new(**defaults, **axes)
    end

    # Minimal lane stub — reject_no_candidates never reads lane methods.
    def stub_lane
      Struct.new(:lane_id).new('local:vllm:h200:inference:stub-model').freeze
    end

    # Minimal publication status stub — reject_no_candidates reads only .state.
    def synth_pub_status(state:)
      Struct.new(:state).new(state).freeze
    end

    # Build an EvaluationSet from synthetic candidates and publication statuses.
    def synth_eval_set(candidates: [], statuses: [], gen: 1)
      Legion::LLM::Routing::EvaluationSet.new(
        candidates:           candidates,
        publication_statuses: statuses,
        inventory_generation: gen
      )
    end

    # Call reject_no_candidates directly on a Router instance.
    def reject(router, candidates: [], statuses: [], gen: 1, model_pin: nil)
      es = synth_eval_set(candidates: candidates, statuses: statuses, gen: gen)
      router.send(:reject_no_candidates, evaluation_set: es, model_pin: model_pin)
    end

    # --------------------------------------------------------------------- #
    # Step 4 guard: unknown op/cap evidence prevents failed_dependency       #
    # --------------------------------------------------------------------- #

    context 'unknown op-evidence prevents failed_dependency (step 4 → step 7 too_early)' do
      it 'returns :too_early 425 when operation_state :unknown mixes with :unsupported' do
        router = build_router
        cands  = [
          synth_candidate(operation_state: :unknown),
          synth_candidate(operation_state: :unsupported)
        ]
        result = reject(router, candidates: cands, statuses: [synth_pub_status(state: :complete)])
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:too_early)
        expect(result.http_status).to eq(425)
      end

      it 'returns :too_early 425 when capability_state :unknown mixes with :unsupported' do
        router = build_router
        cands  = [
          synth_candidate(capability_state: :unknown),
          synth_candidate(capability_state: :unsupported)
        ]
        result = reject(router, candidates: cands, statuses: [synth_pub_status(state: :complete)])
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:too_early)
        expect(result.http_status).to eq(425)
      end
    end

    # --------------------------------------------------------------------- #
    # Step 7: unknown availability_state → :too_early 425                    #
    # --------------------------------------------------------------------- #

    context 'unknown availability_state (step 7 too_early)' do
      it 'returns :too_early 425 for a policy-eligible candidate with availability :unknown' do
        router = build_router
        cands  = [synth_candidate(availability_state: :unknown)]
        result = reject(router, candidates: cands, statuses: [synth_pub_status(state: :complete)])
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:too_early)
        expect(result.http_status).to eq(425)
      end
    end

    # --------------------------------------------------------------------- #
    # Step 7: unknown operation_state (complete scopes) → :too_early 425     #
    # --------------------------------------------------------------------- #

    context 'unknown operation_state with complete scopes (step 7 too_early)' do
      it 'returns :too_early 425 when operation_state is :unknown and all scopes complete' do
        router = build_router
        cands  = [synth_candidate(operation_state: :unknown)]
        result = reject(router, candidates: cands, statuses: [synth_pub_status(state: :complete)])
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:too_early)
        expect(result.http_status).to eq(425)
      end
    end

    # --------------------------------------------------------------------- #
    # Step 6 skipped when fit+available candidate exists → falls to step 7   #
    # --------------------------------------------------------------------- #

    context 'settled-unknown skipped when a conclusively-fit+available candidate exists' do
      it 'returns :too_early 425 (not :invalid_request 400) when fit+available sibling exists' do
        router = build_router
        cands  = [
          # Conclusively fit + available + pin match → fit_available = true
          synth_candidate(exclusion_state: :excluded),
          # Unknown capability — would normally trigger step 6 (400) but
          # fit_available is true, so step 6 is skipped; falls to step 7.
          synth_candidate(capability_state: :unknown)
        ]
        result = reject(router, candidates: cands, statuses: [synth_pub_status(state: :complete)])
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:too_early)
        expect(result.http_status).to eq(425)
      end
    end

    # --------------------------------------------------------------------- #
    # Step 4b: pinned scope conclusively unsupported → :failed_dependency    #
    # (a terminal 424, NOT a retryable 503 — guards the 529 fail-forward     #
    # regression when a capable pin-MISMATCHED sibling exists)               #
    # --------------------------------------------------------------------- #

    context 'pinned scope all operation-unsupported with a capable pin-mismatched sibling (step 4b)' do
      it 'returns :failed_dependency 424, not a retryable :service_unavailable 503' do
        router = build_router
        cands  = [
          # The pinned target: matches the pin but cannot perform the operation.
          synth_candidate(pin_state: :match, operation_state: :unsupported),
          # A fully capable lane under a DIFFERENT provider (pin mismatch) — it must
          # NOT downgrade the terminal pinned failure to a retryable 503.
          synth_candidate(pin_state: :mismatch, operation_state: :supported, capability_state: :supported)
        ]
        result = reject(router, candidates: cands,
                                statuses:   [synth_pub_status(state: :complete)],
                                model_pin:  'nomic-embed')
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:failed_dependency)
        expect(result.http_status).to eq(424)
      end
    end

    # --------------------------------------------------------------------- #
    # candidate_counts per-axis tallies on the Rejection                     #
    # --------------------------------------------------------------------- #

    context 'candidate_counts metadata' do
      it 'carries per-axis tallies reflecting the synthetic candidates' do
        router = build_router
        cands  = [
          synth_candidate(policy_state: :denied),
          synth_candidate(operation_state: :unsupported),
          synth_candidate(capability_state: :unknown)
        ]
        result = reject(router, candidates: cands, statuses: [synth_pub_status(state: :complete)])
        expect(result.candidate_counts).to be_a(Hash)
        expect(result.candidate_counts[:policy_denied]).to eq(1)
        expect(result.candidate_counts[:operation_unsupported]).to eq(1)
        expect(result.candidate_counts[:capability_unknown]).to eq(1)
        expect(result.candidate_counts[:publication_complete]).to eq(1)
      end
    end

    # --------------------------------------------------------------------- #
    # Authoritative :unsupported capability → :failed_dependency 424         #
    # --------------------------------------------------------------------- #

    context 'capability_state :unsupported (authoritative) → failed_dependency' do
      it 'returns :failed_dependency 424 when all candidates are authoritatively unsupported' do
        router = build_router
        cands  = [
          synth_candidate(capability_state: :unsupported),
          synth_candidate(capability_state: :unsupported)
        ]
        result = reject(router, candidates: cands, statuses: [synth_pub_status(state: :complete)])
        expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
        expect(result.kind).to eq(:failed_dependency)
        expect(result.http_status).to eq(424)
      end
    end
  end
end
