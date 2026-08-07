# frozen_string_literal: true

require 'spec_helper'

# Regression coverage for the context-window routing under-count that shipped a
# "final payload estimate NNNNN tokens exceeds dispatch threshold" ContextOverflow
# on small-context local lanes. See docs/work/planning/nxn-debugging-method.md.
#
# Four defects, one oracle:
#   1. estimate_request_tokens used a naive shadow estimator + RAW system.
#   2. routing estimated raw (not lane-independent-reduced) messages.
#   3. step_context_load double-sent history (structured messages + injected
#      "Prior conversation history" system text) for client-managed conversations.
#   4. no offline coverage tied routing's estimate to the dispatch guard.
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
    # A naive m[:content].to_s estimator reads this near-zero; the canonical
    # estimator walks the blocks and sees the real text.
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
    # native_dispatch_options resolves tools/prefs against the registry, which
    # needs a resolved provider/model. Pin the routing-resolved lane.
    executor.instance_variable_set(:@resolved_provider, :vllm)
    executor.instance_variable_set(:@resolved_model, 'gemma-12b-it')
    executor.instance_variable_set(:@resolved_instance, :default)
  end

  describe '#estimate_request_tokens (Part 1 + Part 4)' do
    it 'counts structured content blocks, not a near-zero shadow estimate' do
      estimated = executor.send(:estimate_request_tokens)
      # 20 messages × ~400 words is thousands of tokens; a naive [:content].to_s
      # estimator on an Array returns the inspect string length, wildly wrong.
      expect(estimated).to be > 5_000
    end

    it 'tracks the dispatch guard estimate closely for the same request' do
      # The router filters on estimate_request_tokens; the dispatch guard raises
      # on final_dispatch_token_estimate. If routing materially under-counts vs
      # dispatch, a too-small lane passes the filter then overflows at dispatch.
      # The two are computed over different code paths so are not token-identical,
      # but routing must track dispatch within a small tolerance — never the old
      # thousands-of-tokens undercount (structured content + injected tools/system
      # ignored) that shipped the ContextOverflow.
      dispatch_messages = executor.send(:native_dispatch_messages)
      dispatch_options  = executor.send(:native_dispatch_options)
      dispatch_estimate = executor.send(:final_dispatch_token_estimate, dispatch_messages, dispatch_options)

      routing_estimate = executor.send(:estimate_request_tokens)

      # Routing must never materially under-count dispatch (that was the bug).
      # A small negative delta (tool_prefs / gaia-triggered tools that depend on
      # resolved state routing can't see) is tolerated; a thousands-of-tokens
      # undercount is not.
      expect(routing_estimate).to be >= (dispatch_estimate * 0.95)
    end

    it 'includes the injected system prompt, not just the raw request system' do
      # Put a large enrichment into the system channel; routing must see it.
      executor.instance_variable_set(:@enrichments,
                                     { 'skill:active' => ('skill instruction ' * 2_000) })
      with_enrichment = executor.send(:estimate_request_tokens)

      executor.instance_variable_set(:@enrichments, {})
      without_enrichment = executor.send(:estimate_request_tokens)

      expect(with_enrichment).to be > without_enrichment
    end
  end

  describe '#estimate_request_tokens routes on reduced payload (Part 2)' do
    let(:messages) do
      # A giant tool-result message that trim_oversized_tool_results will shrink
      # before dispatch. Routing must estimate the REDUCED size, not the raw one,
      # so it does not over-escalate off a lane the reduced payload would fit.
      [
        { role: :user, content: 'run the tool' },
        { role: :tool, tool_call_id: 'c1', content: 'RESULT ' * 20_000 },
        { role: :user, content: 'thanks' }
      ]
    end

    it 'reflects the trimmed tool result, not the raw oversized payload' do
      dispatch_messages = executor.send(:native_dispatch_messages)
      dispatch_options  = executor.send(:native_dispatch_options)
      dispatch_estimate = executor.send(:final_dispatch_token_estimate, dispatch_messages, dispatch_options)
      routing_estimate  = executor.send(:estimate_request_tokens)

      # Routing applies only the LANE-INDEPENDENT reductions (empty/thinking/
      # oversized-tool-result trims); it must NOT apply enforce_context_window's
      # lane-dependent compaction because the lane isn't chosen yet. dispatch
      # here DID compact (against the 8192 lane), so routing legitimately sits
      # at or above dispatch — never materially below. Below would be the bug.
      expect(routing_estimate).to be >= (dispatch_estimate * 0.95)

      # And it must reflect the TRIMMED tool result, not the raw 20k-token blob.
      raw_estimate = Legion::LLM::Inference::ContextAccounting.estimate_message_tokens(messages)
      expect(routing_estimate).to be < raw_estimate
    end
  end

  describe 'end-to-end lane selection (Part 4 commit gate)' do
    def write_lane(provider:, model:, limits:, tier: :direct)
      Legion::LLM::Inventory.write_lane(lane: {
                                          id:              "#{tier}:#{provider}:default:inference:#{model}",
                                          tier:            tier, provider_family: provider,
                                          instance_id:     :default, model: model, type: :inference,
                                          capabilities:    [], limits: limits
                                        })
    end

    after { Legion::LLM::Inventory.reset_live_store! }

    # Provider pinned via routing, MODEL unspecified so the router selects the
    # lane by filters+weight — the real "no model, let routing decide" path.
    let(:request) do
      Legion::LLM::Inference::Request.build(messages: messages, system: 'You are a helpful assistant.',
                                            routing: { provider: :vllm })
    end
    # ~11k tokens of content: exceeds 8192*0.9 headroom but fits the 131k lane.
    let(:messages) { [{ role: :user, content: [{ type: 'text', text: 'word ' * 11_000 }] }] }

    it 'skips the small-context lane whose window the injected payload would overflow' do
      write_lane(provider: :vllm, model: 'gemma-12b-it', limits: { context_window: 8_192 })
      write_lane(provider: :vllm, model: 'gemma-4-31b-it', limits: { context_window: 131_072 })

      state = executor.send(:routing_request_state)
      expect(state[:estimated_tokens]).to be > (8_192 * 0.9) # would overflow the small lane

      lane = executor.send(:routing_resolution_for, state)
      expect(lane).not_to be_nil
      expect(lane.model).to eq('gemma-4-31b-it')
    end
  end
end
