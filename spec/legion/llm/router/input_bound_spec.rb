# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/input_bound'

RSpec.describe Legion::LLM::Router::InputBound do
  # G3: InputBound measures the canonical routing input — messages are
  # Canonical::Message (the former Hash double shapes are gone; R15).
  def canon_msg(content)
    Legion::Extensions::Llm::Canonical::Message.build(content: content)
  end

  describe '.call' do
    subject(:bound) { described_class.call(**kwargs) }

    context 'with all nil/empty inputs' do
      let(:kwargs) { { framing_overhead_tokens: 0 } }

      it 'returns 0' do
        expect(bound).to eq(0)
      end

      it 'returns an Integer' do
        expect(bound).to be_a(Integer)
      end
    end

    context 'framing overhead' do
      let(:kwargs) { { framing_overhead_tokens: 1024 } }

      it 'adds the configured overhead' do
        expect(bound).to eq(1024)
      end

      it 'is added even when all content is absent' do
        result = described_class.call(messages: nil, system: nil, framing_overhead_tokens: 500)
        expect(result).to eq(500)
      end
    end

    context 'system prompt byte counting' do
      it 'counts ASCII bytes as byte length' do
        result = described_class.call(system: 'hello', framing_overhead_tokens: 0)
        expect(result).to eq('hello'.bytesize)
      end

      it 'counts multi-byte UTF-8 characters by byte length, not char count' do
        # '€' is U+20AC — 3 bytes in UTF-8, 1 char
        euro = '€'
        result = described_class.call(system: euro, framing_overhead_tokens: 0)
        expect(result).to eq(3) # 3 bytes, not 1 char
        expect(result).not_to eq(1)
      end

      it 'counts a 4-byte UTF-8 emoji by bytes' do
        # '😀' is U+1F600 — 4 bytes in UTF-8
        emoji = "\u{1F600}"
        result = described_class.call(system: emoji, framing_overhead_tokens: 0)
        expect(result).to eq(4)
      end
    end

    context 'messages byte counting' do
      it 'sums string-content messages by byte length' do
        msgs = [canon_msg('hello'), canon_msg('world')]
        result = described_class.call(messages: msgs, framing_overhead_tokens: 0)
        expect(result).to eq('hello'.bytesize + 'world'.bytesize)
      end

      it 'sums array-of-text-blocks messages by byte length' do
        msgs = [canon_msg([Legion::Extensions::Llm::Canonical::ContentBlock.text('hi there')])]
        result = described_class.call(messages: msgs, framing_overhead_tokens: 0)
        expect(result).to eq('hi there'.bytesize)
      end

      it 'counts multi-byte text blocks by bytes not chars' do
        # "日本語" — 3 chars, 9 bytes in UTF-8
        japanese = '日本語'
        msgs = [canon_msg(japanese)]
        result = described_class.call(messages: msgs, framing_overhead_tokens: 0)
        expect(result).to eq(9)
        expect(result).not_to eq(3)
      end

      it 'handles nil messages gracefully' do
        result = described_class.call(messages: nil, framing_overhead_tokens: 0)
        expect(result).to eq(0)
      end

      it 'handles an empty messages array' do
        result = described_class.call(messages: [], framing_overhead_tokens: 0)
        expect(result).to eq(0)
      end

      it 'handles mixed content-block types, counting only text/tool bytes' do
        msgs = [
          canon_msg([
                      Legion::Extensions::Llm::Canonical::ContentBlock.text('hello'),
                      Legion::Extensions::Llm::Canonical::ContentBlock.image(data: 'abc', media_type: 'image/png')
                    ])
        ]
        result = described_class.call(messages: msgs, framing_overhead_tokens: 0)
        # only text block contributes; image block contributes 0
        expect(result).to eq('hello'.bytesize)
      end

      it 'handles tool_use content blocks using serialized input bytes' do
        msgs = [
          canon_msg([
                      Legion::Extensions::Llm::Canonical::ContentBlock.tool_use(id: 'tu_1', name: 'my_tool', input: { x: 1 })
                    ])
        ]
        result = described_class.call(messages: msgs, framing_overhead_tokens: 0)
        name_bytes = 'my_tool'.bytesize
        input_bytes = Legion::JSON.dump({ x: 1 }).bytesize
        expect(result).to eq(name_bytes + input_bytes)
      end

      it 'handles tool_result content blocks' do
        msgs = [
          canon_msg([
                      Legion::Extensions::Llm::Canonical::ContentBlock.tool_result(tool_use_id: 'tu_1', content: 'the result string')
                    ])
        ]
        result = described_class.call(messages: msgs, framing_overhead_tokens: 0)
        expect(result).to eq('the result string'.bytesize)
      end
    end

    context 'structured inputs contribute serialized bytes' do
      it 'adds tool schema bytes when tools are provided' do
        tools = [{ name: 'search', description: 'Search the web', input_schema: { type: 'object' } }]
        serialized = Legion::JSON.dump(tools).bytesize

        result_with    = described_class.call(tools: tools, framing_overhead_tokens: 0)
        result_without = described_class.call(tools: nil, framing_overhead_tokens: 0)

        expect(result_with - result_without).to eq(serialized)
      end

      it 'adds tool_choice bytes when provided' do
        tc = { type: 'auto' }
        serialized = Legion::JSON.dump(tc).bytesize

        result_with    = described_class.call(tool_choice: tc,   framing_overhead_tokens: 0)
        result_without = described_class.call(tool_choice: nil,  framing_overhead_tokens: 0)

        expect(result_with - result_without).to eq(serialized)
      end

      it 'adds thinking config bytes when provided' do
        thinking = { type: 'enabled', budget_tokens: 4096 }
        serialized = Legion::JSON.dump(thinking).bytesize

        result_with    = described_class.call(thinking: thinking, framing_overhead_tokens: 0)
        result_without = described_class.call(thinking: nil,      framing_overhead_tokens: 0)

        expect(result_with - result_without).to eq(serialized)
      end

      it 'adds response_format bytes when provided' do
        rf = { type: 'json_schema', json_schema: { name: 'result', schema: { type: 'object' } } }
        serialized = Legion::JSON.dump(rf).bytesize

        result_with    = described_class.call(response_format: rf,   framing_overhead_tokens: 0)
        result_without = described_class.call(response_format: nil,  framing_overhead_tokens: 0)

        expect(result_with - result_without).to eq(serialized)
      end

      it 'adds operation_payload bytes when provided' do
        op = { temperature: 0.7, max_tokens: 1024 }
        serialized = Legion::JSON.dump(op).bytesize

        result_with    = described_class.call(operation_payload: op,   framing_overhead_tokens: 0)
        result_without = described_class.call(operation_payload: nil,  framing_overhead_tokens: 0)

        expect(result_with - result_without).to eq(serialized)
      end
    end

    context 'summation correctness' do
      it 'adds system + messages + tools + overhead together' do
        system = 'You are helpful.'
        msgs   = [canon_msg('What is 2+2?')]
        tools  = [{ name: 'calc', description: 'calculate', input_schema: {} }]
        overhead = 128

        expected = system.bytesize +
                   'What is 2+2?'.bytesize +
                   Legion::JSON.dump(tools).bytesize +
                   overhead

        result = described_class.call(
          system:                  system,
          messages:                msgs,
          tools:                   tools,
          framing_overhead_tokens: overhead
        )
        expect(result).to eq(expected)
      end

      it 'result is always nonnegative' do
        result = described_class.call(
          system: '', messages: [], tools: nil,
          framing_overhead_tokens: 0
        )
        expect(result).to be >= 0
      end
    end

    context 'chars/4 heuristic is NOT used' do
      it 'a 1000-character ASCII message contributes ~1000 not ~250' do
        long_ascii = 'a' * 1000
        result = described_class.call(messages: [canon_msg(long_ascii)], framing_overhead_tokens: 0)
        # Exact byte match for ASCII: 1000 bytes
        expect(result).to eq(1000)
        # Explicitly not the chars/4 value
        expect(result).not_to eq(250)
        # And the result is closer to char count than to chars/4
        expect(result).to be > 900
      end

      it 'a 100-character ASCII system prompt contributes 100, not 25' do
        prompt = 'x' * 100
        result = described_class.call(system: prompt, framing_overhead_tokens: 0)
        expect(result).to eq(100)
        expect(result).not_to eq(25)
      end
    end

    context 'result type guarantees' do
      it 'always returns an Integer regardless of input variety' do
        result = described_class.call(
          operation:               :chat,
          messages:                [canon_msg('hello')],
          system:                  'You are an assistant.',
          tools:                   [{ name: 'tool1', input_schema: {} }],
          tool_choice:             { type: 'auto' },
          thinking:                { type: 'enabled', budget_tokens: 2048 },
          response_format:         { type: 'json_object' },
          operation_payload:       { temperature: 0.5 },
          framing_overhead_tokens: 1024
        )
        expect(result).to be_a(Integer)
        expect(result).to be >= 0
      end

      it 'accepts operation: keyword without affecting the byte count' do
        without_op = described_class.call(system: 'hello', framing_overhead_tokens: 0)
        with_op    = described_class.call(system: 'hello', operation: :chat, framing_overhead_tokens: 0)
        expect(with_op).to eq(without_op)
      end

      it 'accepts extra unknown kwargs via trailing ** without raising' do
        expect do
          described_class.call(
            system:                  'hi',
            framing_overhead_tokens: 10,
            some_future_key:         'ignored'
          )
        end.not_to raise_error
      end
    end
  end
end
