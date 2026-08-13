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
end
