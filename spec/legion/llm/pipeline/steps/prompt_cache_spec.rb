# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::PromptCache do
  subject(:mod) { described_class }

  before do
    Legion::Settings[:llm][:prompt_caching] = {
      enabled:             false,
      min_tokens:          1024,
      scope:               'ephemeral',
      cache_system_prompt: true,
      cache_tools:         true,
      cache_conversation:  true,
      sort_tools:          true
    }
  end

  let(:long_content) { 'x' * ((1024 * 4) + 1) } # exceeds min_tokens * 4 chars
  let(:short_content) { 'short prompt' }

  # -------------------------------------------------------------------------
  # apply_cache_control
  # -------------------------------------------------------------------------
  describe '.apply_cache_control' do
    context 'when prompt caching is disabled' do
      it 'returns system blocks unchanged' do
        blocks = [{ type: :text, content: long_content }]
        result = mod.apply_cache_control(blocks)
        expect(result).to eq(blocks)
        expect(result.last).not_to have_key(:cache_control)
      end
    end

    context 'when prompt caching is enabled' do
      before { Legion::Settings[:llm][:prompt_caching][:enabled] = true }

      it 'adds cache_control to the last system block when content exceeds min_tokens' do
        blocks = [{ type: :text, content: long_content }]
        result = mod.apply_cache_control(blocks)
        expect(result.last[:cache_control]).to eq({ type: 'ephemeral' })
      end

      it 'does not add cache_control when content is shorter than min_tokens' do
        blocks = [{ type: :text, content: short_content }]
        result = mod.apply_cache_control(blocks)
        expect(result.last).not_to have_key(:cache_control)
      end

      it 'only marks the last block when multiple blocks are present' do
        blocks = [
          { type: :text, content: 'A' * 2000 },
          { type: :text, content: 'B' * 2500 }
        ]
        result = mod.apply_cache_control(blocks)
        expect(result.first).not_to have_key(:cache_control)
        expect(result.last[:cache_control]).to eq({ type: 'ephemeral' })
      end

      it 'uses the configured scope from settings' do
        Legion::Settings[:llm][:prompt_caching][:scope] = 'persistent'
        blocks = [{ type: :text, content: long_content }]
        result = mod.apply_cache_control(blocks)
        expect(result.last[:cache_control]).to eq({ type: 'persistent' })
      end

      it 'returns the original blocks unchanged when the array is empty' do
        expect(mod.apply_cache_control([])).to eq([])
      end

      it 'returns nil unchanged' do
        expect(mod.apply_cache_control(nil)).to be_nil
      end

      context 'when cache_system_prompt is false' do
        before { Legion::Settings[:llm][:prompt_caching][:cache_system_prompt] = false }

        it 'does not add cache_control even when content is long' do
          blocks = [{ type: :text, content: long_content }]
          result = mod.apply_cache_control(blocks)
          expect(result.last).not_to have_key(:cache_control)
        end
      end
    end
  end

  # -------------------------------------------------------------------------
  # sort_tools_deterministically
  # -------------------------------------------------------------------------
  describe '.sort_tools_deterministically' do
    let(:tools) do
      [
        { name: 'zebra', description: 'z tool' },
        { name: 'alpha', description: 'a tool' },
        { name: 'mango', description: 'm tool' }
      ]
    end

    context 'when prompt caching is disabled' do
      it 'returns tools unchanged' do
        result = mod.sort_tools_deterministically(tools)
        expect(result.map { |t| t[:name] }).to eq(%w[zebra alpha mango])
      end
    end

    context 'when prompt caching is enabled' do
      before { Legion::Settings[:llm][:prompt_caching][:enabled] = true }

      it 'sorts tools by name alphabetically' do
        result = mod.sort_tools_deterministically(tools)
        expect(result.map { |t| t[:name] }).to eq(%w[alpha mango zebra])
      end

      it 'returns an empty array unchanged' do
        expect(mod.sort_tools_deterministically([])).to eq([])
      end

      it 'returns nil unchanged' do
        expect(mod.sort_tools_deterministically(nil)).to be_nil
      end

      context 'when cache_tools (sort_tools) is false' do
        before { Legion::Settings[:llm][:prompt_caching][:sort_tools] = false }

        it 'returns tools in original order' do
          result = mod.sort_tools_deterministically(tools)
          expect(result.map { |t| t[:name] }).to eq(%w[zebra alpha mango])
        end
      end
    end
  end

  # -------------------------------------------------------------------------
  # apply_conversation_breakpoint
  # -------------------------------------------------------------------------
  describe '.apply_conversation_breakpoint' do
    let(:messages) do
      [
        { role: :user, content: 'first message' },
        { role: :assistant, content: 'first reply' },
        { role: :user, content: 'current question' }
      ]
    end

    context 'when prompt caching is disabled' do
      it 'returns messages unchanged' do
        result = mod.apply_conversation_breakpoint(messages)
        expect(result).to eq(messages)
      end
    end

    context 'when prompt caching is enabled' do
      before { Legion::Settings[:llm][:prompt_caching][:enabled] = true }

      it 'adds a cache breakpoint after the last prior stable message' do
        result = mod.apply_conversation_breakpoint(messages)
        # The last prior message (index 1) should get cache_control
        expect(result[1][:cache_control]).to eq({ type: 'ephemeral' })
        # The current message (last) should not be modified
        expect(result.last).not_to have_key(:cache_control)
      end

      it 'does not modify the original messages array' do
        mod.apply_conversation_breakpoint(messages)
        expect(messages[1]).not_to have_key(:cache_control)
      end

      it 'returns a single-message list unchanged (nothing to mark as prior)' do
        single = [{ role: :user, content: 'hello' }]
        result = mod.apply_conversation_breakpoint(single)
        expect(result).to eq(single)
      end

      it 'returns an empty array unchanged' do
        expect(mod.apply_conversation_breakpoint([])).to eq([])
      end

      it 'returns nil unchanged' do
        expect(mod.apply_conversation_breakpoint(nil)).to be_nil
      end

      it 'does not double-mark messages that already have cache_control' do
        already_marked = [
          { role: :user, content: 'msg1', cache_control: { type: 'ephemeral' } },
          { role: :assistant, content: 'msg2', cache_control: { type: 'ephemeral' } },
          { role: :user, content: 'new question' }
        ]
        result = mod.apply_conversation_breakpoint(already_marked)
        # All prior messages already have cache_control, no unmarked stable message found
        expect(result.last).not_to have_key(:cache_control)
      end

      context 'when cache_conversation is false' do
        before { Legion::Settings[:llm][:prompt_caching][:cache_conversation] = false }

        it 'returns messages unchanged' do
          result = mod.apply_conversation_breakpoint(messages)
          expect(result).to eq(messages)
        end
      end
    end
  end

  # -------------------------------------------------------------------------
  # Cache token usage parsing (verify the module is accessible in executor context)
  # -------------------------------------------------------------------------
  describe 'cache token fields in response' do
    it 'extract_tokens picks up cache_read_tokens and cache_write_tokens from raw_response' do
      raw = double(
        input_tokens:       100,
        output_tokens:      50,
        cache_read_tokens:  80,
        cache_write_tokens: 20
      )

      executor_class = Class.new do
        include Legion::LLM::Pipeline::Steps::PostResponse

        def initialize(raw_response, provider, model)
          @raw_response      = raw_response
          @resolved_provider = provider
          @resolved_model    = model
          @request           = Legion::LLM::Pipeline::Request.build(
            messages: [{ role: :user, content: 'hi' }]
          )
          @enrichments = {}
          @audit       = {}
          @timeline    = Legion::LLM::Pipeline::Timeline.new
          @tracing     = nil
          @warnings    = []
        end
      end

      executor = executor_class.new(raw, :anthropic, 'claude-sonnet-4-6')
      usage = executor.send(:extract_tokens)

      expect(usage.cache_read_tokens).to  eq(80)
      expect(usage.cache_write_tokens).to eq(20)
      expect(usage.input_tokens).to       eq(100)
      expect(usage.output_tokens).to      eq(50)
    end
  end
end
