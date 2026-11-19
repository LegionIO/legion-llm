# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor, 'context window enforcement' do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello world' }],
      tools:    tools,
      routing:  { provider: :vllm, model: 'gemma-4-31b-it' }
    )
  end
  let(:tools) { [] }
  let(:executor) { described_class.new(request) }

  before do
    allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(true)
    allow(Legion::LLM::Audit).to receive(:emit_prompt)
  end

  describe '#enforce_context_window' do
    context 'when tool definitions push total tokens over the context window' do
      let(:tools) do
        # 235 tool definitions, each ~300 chars of JSON schema = ~75 tokens each
        # Total tool budget: ~17,500 tokens
        235.times.map do |i|
          Legion::LLM::Types::ToolDefinition.build(
            name:        "tool_#{i}",
            description: "A tool that does thing #{i} with a moderately long description to simulate real tool schemas",
            parameters:  {
              type:       'object',
              properties: {
                command: { type: 'string', description: "The command to execute for tool #{i}" },
                timeout: { type: 'integer', description: 'Optional timeout in milliseconds' }
              },
              required:   ['command']
            }
          )
        end
      end

      it 'accounts for tool definitions in the token budget' do
        # Simulate: messages alone are small, but messages + 235 tools exceeds window
        # Context window = 262,144 tokens
        # Tools alone at ~75 tokens each × 235 = ~17,625 tokens
        # Messages need to fit in (262,144 * 0.90) - tool_budget
        executor.instance_variable_set(:@resolved_offering_metadata, { limits: { context_window: 262_144 } })

        # G3: the context window operates on canonical messages — the former
        # Hash message doubles are gone (R15).
        large_messages = Array.new(500) do |i|
          Legion::Extensions::Llm::Canonical::Message.build(
            role: (i.even? ? :user : :assistant), content: 'x' * 1800
          )
        end

        result = executor.send(:enforce_context_window, large_messages)

        # The key assertion: enforce_context_window MUST compact when
        # messages + tool budget would exceed the context window
        total_message_tokens = executor.send(:estimate_message_tokens, result)
        tool_token_budget = executor.send(:estimate_tool_token_budget)
        context_window = 262_144
        threshold = (context_window * 0.90).to_i

        expect(total_message_tokens + tool_token_budget).to be <= threshold
      end
    end

    context 'when messages alone are under threshold but tools are not accounted' do
      it 'must not report safe utilization when tools would push over limit' do
        executor.instance_variable_set(:@resolved_offering_metadata, { limits: { context_window: 262_144 } })

        # Reproduce the exact failure scenario:
        # - 10 retained messages totaling ~14k tokens (5.48% of 262k)
        # - But 235 tools add ~17.5k tokens
        # - Plus the actual client messages are 250k tokens
        # The old code only saw the messages and said "5.48% — fine!"
        # G3: canonical messages (the former Hash double shape is gone).
        messages = Array.new(10) do |i|
          Legion::Extensions::Llm::Canonical::Message.build(
            role: (i.even? ? :user : :assistant), content: 'x' * 5600
          )
        end

        # With tool awareness, this should still pass (10 small messages + tools < threshold)
        result = executor.send(:enforce_context_window, messages)
        expect(result.size).to eq(10)
      end
    end
  end

  describe '#estimate_tool_token_budget' do
    context 'with no tools' do
      it 'returns 0' do
        expect(executor.send(:estimate_tool_token_budget)).to eq(0)
      end
    end

    context 'with client-provided tools' do
      let(:tools) do
        30.times.map do |i|
          Legion::LLM::Types::ToolDefinition.build(
            name:        "tool_#{i}",
            description: "Tool #{i}",
            parameters:  { type: 'object', properties: {} }
          )
        end
      end

      it 'returns a positive estimate proportional to tool count' do
        budget = executor.send(:estimate_tool_token_budget)
        expect(budget).to be > 0
        expect(budget).to be > 500 # 30 tools should be at least 500 tokens
      end
    end
  end

  describe 'annotated history text' do
    it 'strips a leading thinking tag across cached blocks without moving media or changing recent history' do
      assistant = Legion::Extensions::Llm::Canonical::Message.build(role: :assistant, content: [
                                                                      { type: :text, text: '<thi' },
                                                                      { type: :text, text: 'nk>private</thi' },
                                                                      { type: :text, text: "nk>\nvisible", cache_control: { type: 'ephemeral' }, metadata: { origin: 'history' } },
                                                                      { type: :image, source_type: :url, data: 'https://example.com/image.png' }
                                                                    ])
      user = Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'Continue.')
      original = Legion::JSON.dump(assistant)
      result = executor.send(:strip_thinking_pure, [assistant, user, assistant])

      expect(result.first.text).to eq('visible')
      expect(result.first.content.first.cache_control).to eq(type: 'ephemeral')
      expect(result.first.content.first.metadata).to eq(origin: 'history')
      expect(result.first.content.last).to equal(assistant.content.last)
      expect(result.last).to equal(assistant)
      expect(Legion::JSON.dump(assistant)).to eq(original)
    end

    it 'recognizes a fully stripped single text block as empty without pruning a tool call' do
      block = Legion::Extensions::Llm::Canonical::ContentBlock.text('<think>private</think>', cache_control: { type: 'ephemeral' })
      assistant = Legion::Extensions::Llm::Canonical::Message.build(role: :assistant, content: block)
      stripped = executor.send(:strip_thinking_pure, [assistant]).first
      with_tool = stripped.with(tool_calls: [Legion::Extensions::Llm::Canonical::ToolCall.build(name: 'lookup', arguments: {})])

      expect(stripped.content).to be_nil
      expect(executor.send(:empty_assistant_message?, stripped)).to be(true)
      expect(executor.send(:empty_assistant_message?, with_tool)).to be(false)
      expect(assistant.content).to equal(block)
    end

    it 'applies one text cap across tool-result blocks while retaining media, annotations and the current turn' do
      # Real settings, real mutation (standards §3): the per-example
      # before(:each) resets Legion::Settings to defaults, so this is isolated.
      Legion::Settings[:llm][:tools][:result_max_dispatch_chars] = 4
      tool = Legion::Extensions::Llm::Canonical::Message.build(role: :tool, tool_call_id: 'lookup-1', content: [
                                                                 { type: :text, text: 'ab', metadata: { origin: 'first' } },
                                                                 { type: :image, source_type: :url, data: 'https://example.com/image.png' },
                                                                 { type: :text, text: 'cdef', cache_control: { type: 'ephemeral' }, metadata: { origin: 'second' } },
                                                                 { type: :text, text: 'TAIL' }
                                                               ])
      user = Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'Continue.')
      original = Legion::JSON.dump(tool)
      result = executor.send(:trim_oversized_tool_results_pure, [tool, user, tool])

      expect(result.first.text.split("\n\n", 2).first).to eq('abcd')
      expect(result.first.text).not_to include('TAIL')
      expect(result.first.tool_call_id).to eq('lookup-1')
      expect(result.first.content[0]).to equal(tool.content[0])
      expect(result.first.content[1]).to equal(tool.content[1])
      expect(result.first.content[2].cache_control).to eq(type: 'ephemeral')
      expect(result.first.content[2].metadata).to eq(origin: 'second')
      expect(result.last).to equal(tool)
      expect(Legion::JSON.dump(tool)).to eq(original)
    end
  end
end
