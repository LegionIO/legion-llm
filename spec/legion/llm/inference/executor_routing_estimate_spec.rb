# frozen_string_literal: true

require 'spec_helper'

# Regression coverage for the context-window routing under-count that shipped a
# "final payload estimate NNNNN tokens exceeds dispatch threshold" ContextOverflow
# on small-context local lanes. See docs/work/planning/nxn-debugging-method.md.
#
# SSOT v3 rewrite: the deleted estimate_request_tokens / routing_request_state /
# routing_resolution_for methods are replaced by:
#   - InputBound.call(...)          → conservative byte-based input bound
#   - build_ssot_v3_routing_requirements → sets @routing_requirements
#   - Router.next_lane(...)          → selects the winning lane from a snapshot
#
# Three invariants survive:
#   1. InputBound counts structured content blocks correctly (not near-zero).
#   2. Routing input bound is never materially below dispatch token estimate
#      (byte count >= token count by InputBound contract).
#   3. Router.next_lane skips lanes whose context window the estimated payload
#      would overflow (CandidateEvaluator §9.7 step 5).
RSpec.describe Legion::LLM::Inference::Executor, 'routing token estimate parity' do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: messages,
      system:   'You are a helpful assistant.',
      routing:  { provider: :vllm, model: 'gemma-12b-it' }
    )
  end
  let(:messages) do
    # Structured content (array of content blocks), the shape Claude Code sends.
    # A naive m[:content].to_s estimator reads this near-zero; InputBound
    # walks the blocks and sees the real byte count.
    Array.new(20) do |i|
      {
        role:    (i.even? ? :user : :assistant),
        content: [{ type: 'text', text: "turn #{i} " + ('word ' * 400) }]
      }
    end
  end
  let(:executor) { described_class.new(request) }

  before do
    allow(Legion::LLM::Audit).to receive(:emit_prompt)
    executor.instance_variable_set(:@enrichments, {})
    executor.instance_variable_set(:@resolved_offering_metadata, { limits: { context_window: 8192 } })
    executor.instance_variable_set(:@resolved_provider, :vllm)
    executor.instance_variable_set(:@resolved_model, 'gemma-12b-it')
    executor.instance_variable_set(:@resolved_instance, :default)
  end

  describe 'InputBound (replaces estimate_request_tokens — Part 1 + Part 4)' do
    it 'counts structured content blocks, not a near-zero shadow estimate' do
      # InputBound.call counts UTF-8 bytes of all textual content blocks.
      # 20 messages × ~400 words × ~5 bytes/word is tens of thousands of bytes;
      # a naive [:content].to_s estimator on an Array returns near-zero.
      bound = Legion::LLM::Router::InputBound.call(
        messages: messages, system: 'You are a helpful assistant.'
      )
      expect(bound).to be > 5_000
    end

    it 'routing input bound is never materially below dispatch token estimate' do
      # InputBound counts bytes (1 byte >= 1 token by contract) so the
      # bound is always >= a token-based dispatch estimate.
      # This guards against any regression that would make routing UNDER-count
      # the payload (the original bug that shipped ContextOverflow at dispatch).
      executor.send(:build_ssot_v3_routing_requirements)
      routing_bound = executor.instance_variable_get(:@routing_requirements).estimated_input_bound

      dispatch_messages = executor.send(:native_dispatch_messages)
      dispatch_options  = executor.send(:native_dispatch_options)
      dispatch_estimate = executor.send(:final_dispatch_token_estimate, dispatch_messages, dispatch_options)

      # By InputBound contract (bytes >= tokens), routing bound >= dispatch estimate.
      expect(routing_bound).to be >= dispatch_estimate
    end
  end

  describe 'end-to-end lane selection — context filter (Part 4 commit gate)' do
    # Write a single vllm instance with two offerings at different context sizes.
    def write_lane_with_context(model:, context:)
      SsotV3SnapshotFactory.activate(
        provider_family: 'vllm',
        instance_id:     model.tr('.', '-'),
        callable:        SsotV3SnapshotFactory::FactoryCallable.new,
        drafts:          [SsotV3SnapshotFactory.offering_draft(
          model:     model,
          tier:      :local,
          supported: %i[chat stream_chat count_tokens],
          context:   context
        )]
      )
    end

    after { Legion::Extensions::Llm::Inventory::Registry.reset! }

    # ~11k words = ~55k bytes > 8192×0.9 threshold; fits the 131k lane.
    let(:messages) { [{ role: :user, content: [{ type: 'text', text: 'word ' * 11_000 }] }] }

    # Provider pinned to vllm, no model pin — router selects the fitting lane.
    let(:request) do
      Legion::LLM::Inference::Request.build(
        messages: messages,
        system:   'You are a helpful assistant.',
        routing:  { provider: :vllm }
      )
    end

    it 'skips the small-context lane whose window the injected payload would overflow' do
      write_lane_with_context(model: 'gemma-12b-it',   context: 8_192)
      write_lane_with_context(model: 'gemma-4-31b-it', context: 131_072)

      executor.send(:build_ssot_v3_routing_requirements)
      reqs = executor.instance_variable_get(:@routing_requirements)

      # Routing bound must exceed the small lane's effective headroom.
      expect(reqs.estimated_input_bound).to be > (8_192 * 0.9)

      snap = Legion::Extensions::Llm::Inventory::Registry.snapshot
      result = Legion::LLM::Router.next_lane(
        requirements: reqs, exclusions: [], snapshot: snap
      )
      expect(result).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(result.model).to eq('gemma-4-31b-it')
    end
  end
end
