# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/inference/attempt_context'
require 'legion/llm/call/selection_dispatch'

RSpec.describe Legion::LLM::Call::SelectionDispatch, :ssot_v3 do
  let(:described) { described_class }

  def chat_context
    activate(provider_family: 'vllm', instance_id: 'h200',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat])])
    snap = snapshot
    sel = selection_for(snapshot: snap, provider_family: 'vllm', instance_id: 'h200',
                        model: 'gemma4', operation: :chat)
    Legion::LLM::Inference::AttemptContext.build(selection: sel, snapshot: snap, attempt_number: 1)
  end

  # Publish one vllm instance with +callable+ and return [AttemptContext, callable_handle]
  # for a :chat selection of 'gemma4' — the SSOT v3 dispatch setup shared by the
  # error-normalization regression examples below.
  def dispatch_context_and_handle(instance_id:, callable:)
    activate(provider_family: 'vllm', instance_id: instance_id,
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat])],
             callable: callable)
    snap = snapshot
    sel = selection_for(snapshot: snap, provider_family: 'vllm', instance_id: instance_id,
                        model: 'gemma4', operation: :chat)
    ctx = Legion::LLM::Inference::AttemptContext.build(selection: sel, snapshot: snap, attempt_number: 1)
    [ctx, sel.callable_handle]
  end

  def message_operation_contexts(callable:)
    activate(
      provider_family: 'openai', instance_id: 'env', callable: callable,
      drafts: [offering_draft(model: 'gpt-test', supported: %i[chat stream_chat count_tokens])]
    )
    snap = snapshot
    %i[chat stream_chat count_tokens].to_h do |operation|
      selection = selection_for(
        snapshot: snap, provider_family: 'openai', instance_id: 'env',
        model: 'gpt-test', operation: operation
      )
      context = Legion::LLM::Inference::AttemptContext.build(
        selection: selection, snapshot: snap, attempt_number: 1
      )
      [operation, context]
    end
  end

  describe 'Result' do
    it 'success carries value and a success outcome' do
      r = described_class::Result.success(value: { ok: true })
      expect(r).to be_success
      expect(r.value).to eq(ok: true)
      expect(r.outcome.kind).to eq(:success)
    end

    it 'failure requires a non-success outcome and nils value' do
      outcome = Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: :provider_error, reason: 'boom')
      r = described_class::Result.failure(outcome: outcome)
      expect(r).to be_failure
      expect(r.value).to be_nil
      expect(r.outcome.kind).to eq(:provider_error)
    end

    it 'failure rejects a success outcome' do
      ok = Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: :success, reason: 'ok')
      expect { described_class::Result.failure(outcome: ok) }.to raise_error(ArgumentError)
    end
  end

  it 'acquires the exact handle, invokes chat, returns success, and releases the lease' do
    ctx = chat_context
    handle = ctx.selection.callable_handle
    result = described.call(attempt_context: ctx, arguments: { messages: [{ role: 'user', content: 'hi' }] })
    expect(result).to be_success
    expect(result.value[:op]).to eq(:chat)
    expect(handle.reference_count).to eq(0)
  end

  it 'rehydrates hash messages for every exact message operation without mutating the input' do
    calls = []
    callable = Class.new(SsotV3SnapshotFactory::FactoryCallable) do
      define_method(:chat) do |messages:, model:, **|
        calls << { operation: :chat, messages: messages, model: model }
        { content: 'ok' }
      end
      define_method(:stream_chat) do |messages:, model:, **, &block|
        calls << { operation: :stream_chat, messages: messages, model: model, block: block }
        { content: 'ok' }
      end
      define_method(:count_tokens) do |messages:, model:, **|
        calls << { operation: :count_tokens, messages: messages, model: model }
        1
      end
    end.new
    contexts = message_operation_contexts(callable: callable)
    legacy_message = Legion::Extensions::Llm::Message.new(role: :assistant, content: 'legacy')
    raw_messages = [
      { role: 'system', content: 'rules' },
      {
        role: 'assistant', content: '', cache_control: { type: 'ephemeral' },
        tool_calls: [{ id: 'call-1', name: 'lookup', arguments: { query: 'status' } }]
      },
      { 'role' => 'tool', 'tool_call_id' => 'call-1', 'content' => 'clean' },
      legacy_message
    ]
    original = raw_messages[0, 3].map(&:dup)

    contexts.each do |operation, context|
      stream_block = proc { |_chunk| nil } if operation == :stream_chat
      described.call(attempt_context: context, arguments: { messages: raw_messages }, &stream_block)
    end

    expect(calls.map { |call| call[:operation] }).to eq(%i[chat stream_chat count_tokens])
    calls.each do |call|
      expect(call[:messages][0, 3]).to all(be_a(Legion::Extensions::Llm::Canonical::Message))
      expect(call[:messages].last).to equal(legacy_message)
      expect(call[:messages].map(&:role)).to eq(%i[system assistant tool assistant])
      expect(call[:messages][1].tool_calls.first.name).to eq('lookup')
      expect(call[:messages][2].tool_call_id).to eq('call-1')
      expect(call[:messages][1].to_h).not_to have_key(:cache_control)
    end
    expect(calls.find { |call| call[:operation] == :stream_chat }[:block]).to be_a(Proc)
    expect(raw_messages[0, 3]).to eq(original)
  end

  it 'rejects an invalid hash message role before acquiring a callable lease' do
    ctx = chat_context
    handle = ctx.selection.callable_handle

    expect do
      described.call(attempt_context: ctx, arguments: { messages: [{ role: 'invalid', content: 'hi' }] })
    end.to raise_error(ArgumentError, /Invalid role/)
    expect(handle.reference_count).to eq(0)
  end

  it 'rejects an arguments[:model] override' do
    ctx = chat_context
    expect do
      described.call(attempt_context: ctx, arguments: { messages: [], model: 'other' })
    end.to raise_error(ArgumentError, /model/)
  end

  it 'requires the operation protected key' do
    ctx = chat_context
    expect do
      described.call(attempt_context: ctx, arguments: {})
    end.to raise_error(ArgumentError, /messages/)
  end

  it 'normalizes a provider StandardError into a failure outcome and releases' do
    activate(provider_family: 'vllm', instance_id: 'boom',
             drafts: [offering_draft(model: 'gemma4', supported: %i[chat])],
             callable: SsotV3SnapshotFactory::FactoryCallable.new(
               responder: ->(_op, _a, _k, _b) { raise 'kaboom' }
             ))
    snap = snapshot
    sel = selection_for(snapshot: snap, provider_family: 'vllm', instance_id: 'boom',
                        model: 'gemma4', operation: :chat)
    ctx = Legion::LLM::Inference::AttemptContext.build(selection: sel, snapshot: snap, attempt_number: 1)
    handle = sel.callable_handle
    result = described.call(attempt_context: ctx, arguments: { messages: [] })
    expect(result).to be_failure
    expect(result.outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    expect(handle.reference_count).to eq(0)
  end

  # Regression (dispatch boundary, SSOT v3): a provider error message can arrive
  # as ASCII-8BIT — raw provider response bodies, Ruby kernel error messages.
  # The production adapter normalizers (e.g. lex-llm-vllm) pass the bounded error
  # message as the outcome reason, and RecordSupport#sanitized_reason once RAISED
  # ValidationError 'is not valid UTF-8' on such a reason — masking the real
  # dispatch error as an unclassifiable retriable 500. It now coerces to valid
  # UTF-8, so a non-UTF-8 provider error normalizes to a typed outcome, never a
  # crash. The offline router suite (selection only, ASCII FakeProvider) never
  # covered this boundary.
  it 'normalizes a non-UTF-8 provider error message into a valid-UTF-8 failure outcome, never a raise' do
    raw = "provider 500 \xFF\x80 truncated".dup.force_encoding(Encoding::BINARY)
    callable = Class.new(SsotV3SnapshotFactory::FactoryCallable) do
      # Mirrors the production adapter normalizer: the bounded error message IS the reason.
      define_method(:normalize_dispatch_error) do |error:|
        llm = Legion::Extensions::Llm
        reason = error.message.to_s[0, 512]
        llm::Routing::ProviderOutcome.new(kind: :provider_error, reason: reason.empty? ? 'unknown dispatch error' : reason)
      end
    end.new(responder: ->(_op, _a, _k, _b) { raise raw })
    ctx, handle = dispatch_context_and_handle(instance_id: 'utf8', callable: callable)
    result = described.call(attempt_context: ctx, arguments: { messages: [] })
    expect(result).to be_failure
    expect(result.value).to be_nil
    expect(result.outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    expect(result.outcome.kind).to eq(:provider_error)
    expect(result.outcome.reason).to be_a(String)
    expect(result.outcome.reason.encoding).to eq(Encoding::UTF_8)
    expect(result.outcome.reason).to be_valid_encoding
    expect(handle.reference_count).to eq(0)
  end

  # Regression (same incident, observability): a normalizer that raises must
  # never mask the provider error it was asked to classify. The normalize
  # rescue logs the ORIGINAL dispatch error's class and scrubbed message before
  # re-raising the programming failure. Pre-fix, the non-UTF-8 ValidationError
  # from sanitized_reason escaped SelectionDispatch with the original dispatch
  # error lost entirely from the daemon log.
  it 'logs the original dispatch error class and message when the normalizer itself raises' do
    raw = "provider 500 \xFF\x80 truncated".dup.force_encoding(Encoding::BINARY)
    original = RuntimeError.new(raw)
    normalizer_error = Legion::Extensions::Llm::Inventory::Errors::ValidationError.new('reason is not valid UTF-8')
    callable = Class.new(SsotV3SnapshotFactory::FactoryCallable) do
      define_method(:normalize_dispatch_error) do |error:|
        _ = error
        raise normalizer_error
      end
    end.new(responder: ->(_op, _a, _k, _b) { raise original })
    ctx, handle = dispatch_context_and_handle(instance_id: 'normfail', callable: callable)
    allow(described_class).to receive(:handle_exception)
    expect { described.call(attempt_context: ctx, arguments: { messages: [] }) }.to raise_error(normalizer_error)
    expect(described_class).to have_received(:handle_exception).with(
      normalizer_error,
      hash_including(
        level:                  :warn,
        handled:                false,
        original_error_class:   'RuntimeError',
        original_error_message: 'provider 500 ?? truncated'
      )
    )
    expect(handle.reference_count).to eq(0)
  end
end
