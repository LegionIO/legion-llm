# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'
require 'legion/llm/call/selection_dispatch'
require 'legion/llm/api/stream_assembler'

# SSOT v4 §19 / Task 11 — post-first-byte streaming failover.
#
# Proves the executor's SSOT streaming loop, after a provider fails MID-STREAM
# (bytes already emitted), re-selects the next eligible lane through the SAME
# Router instance, drives the StreamAssembler failover sequence
# (provider_failover_pending! then begin_dispatch_on), and continues the same
# SSE session without replaying already-emitted content.

# Minimal emitter that records text deltas so we can prove continue-not-replay.
class FailoverRecordingEmitter
  attr_reader :text_deltas

  def initialize
    @text_deltas = []
  end

  def on_text_delta(block_index:, text:)
    _ = block_index
    @text_deltas << text
  end

  def method_missing(_name, *_args, **)
    nil
  end

  def respond_to_missing?(_name, _include_private = false)
    true
  end
end

RSpec.describe Legion::LLM::Inference::Executor, 'SSOT v3 streaming failover', :ssot_v3 do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:routing) { Legion::Extensions::Llm::Routing }

  def two_stream_instances
    %w[h200 helios1].each do |instance_id|
      activate(
        provider_family: 'vllm', instance_id: instance_id,
        drafts: [offering_draft(model: 'gemma4', supported: %i[stream_chat],
                                capabilities: { streaming: :supported }, context: 200_000)]
      )
    end
  end

  def build_stream_router(request)
    Legion::LLM::Router.new(
      request: request, operation: :stream_chat,
      body_model: request.metadata[:client_model]
    )
  end

  def text_chunk(delta)
    canonical::Chunk.text_delta(delta: delta, request_id: 'req_failover', block_index: 0, item_id: 'msg')
  end

  it 're-selects the next lane through the same router and continues the SSE after a mid-stream failure' do
    two_stream_instances

    request = Legion::LLM::Inference::Request.build_for_test(
      routing_seed: 'ab' * 16, messages: [{ role: :user, content: 'hi' }],
      routing: { model: 'gemma4' }, stream: true
    )
    router = build_stream_router(request)
    first_attempt = router.next_attempt!

    executor = described_class.new(request)
    executor.instance_variable_set(:@router, router)
    executor.instance_variable_set(:@current_attempt_context, first_attempt)

    emitter = FailoverRecordingEmitter.new
    assembler = Legion::LLM::API::StreamAssembler.new(
      emitter: emitter, request_id: 'req_failover', model: 'gemma4',
      initial_lane: executor.send(:ssot_v3_stream_lane_hash, first_attempt)
    )
    executor.instance_variable_set(:@stream_observer, assembler)

    # Attempt 1 emits a client-visible byte, then the provider fails retriably
    # (overloaded). Attempt 2 (a different instance) succeeds.
    calls = 0
    allow(executor).to receive(:execute_provider_request_stream) do |&blk|
      calls += 1
      if calls == 1
        blk.call(text_chunk('one'))
        # M3.3: the typed outcome rides on the raised error (no side-channel).
        raise Legion::LLM::ProviderError.new(
          'provider overloaded',
          outcome: routing::ProviderOutcome.new(kind: :overloaded, reason: 'busy')
        )
      else
        blk.call(text_chunk('two'))
        executor.instance_variable_set(:@raw_response, :ok)
      end
    end

    first_lane_id = first_attempt.selection.lane_id
    expect(assembler).to receive(:provider_failover_pending!)
      .with(from: hash_including(id: first_lane_id)).and_call_original
    expect(assembler).to receive(:begin_dispatch_on)
      .with(hash_including(lane: hash_including(:id))).and_call_original

    executor.send(:run_provider_call_ssot_v3_stream_loop, session: router, attempt_context: first_attempt) do |chunk|
      assembler.push(chunk)
    end

    # Two dispatch attempts, two DISTINCT consumed targets through one router.
    expect(calls).to eq(2)
    expect(router.consumed_targets.size).to eq(2)
    expect(router.consumed_targets.uniq.size).to eq(2)

    # The SSE continued: both bytes reached the client, 'one' exactly once (no replay).
    expect(emitter.text_deltas).to eq(%w[one two])
  end

  it 'raises (terminal SSE error) when no replacement lane remains after a mid-stream failure' do
    # Only one instance: after it is consumed, next_attempt has no other lane.
    activate(
      provider_family: 'vllm', instance_id: 'h200',
      drafts: [offering_draft(model: 'gemma4', supported: %i[stream_chat],
                              capabilities: { streaming: :supported }, context: 200_000)]
    )

    request = Legion::LLM::Inference::Request.build_for_test(
      routing_seed: 'cd' * 16, messages: [{ role: :user, content: 'hi' }],
      routing: { model: 'gemma4' }, stream: true
    )
    router = build_stream_router(request)
    first_attempt = router.next_attempt!

    executor = described_class.new(request)
    executor.instance_variable_set(:@router, router)
    executor.instance_variable_set(:@current_attempt_context, first_attempt)

    allow(executor).to receive(:execute_provider_request_stream) do |&_blk|
      # M3.3: the typed outcome rides on the raised error (no side-channel).
      raise Legion::LLM::ProviderError.new(
        'provider overloaded',
        outcome: routing::ProviderOutcome.new(kind: :overloaded, reason: 'busy')
      )
    end

    expect do
      executor.send(:run_provider_call_ssot_v3_stream_loop, session: router, attempt_context: first_attempt) { |_c| nil }
    end.to raise_error(Legion::LLM::ProviderError)
  end
end
