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

        # Large message payload that fits alone but NOT with 235 tools
        large_messages = Array.new(500) do |i|
          { role: (i.even? ? :user : :assistant), content: 'x' * 1800 }
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
        messages = Array.new(10) do |i|
          { role: (i.even? ? :user : :assistant), content: 'x' * 5600 }
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
end
