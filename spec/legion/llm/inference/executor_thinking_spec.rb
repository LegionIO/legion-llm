# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor do
  describe '#native_dispatch_chat_options' do
    context 'when @request.thinking is nil' do
      let(:request) do
        Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'hello' }],
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' }
        )
      end

      it 'does not include thinking key in options' do
        executor = described_class.new(request)
        executor.instance_variable_set(:@resolved_provider, :anthropic)
        executor.instance_variable_set(:@resolved_model, 'claude-opus-4-6')
        opts = executor.send(:native_dispatch_chat_options)
        expect(opts).not_to have_key(:thinking)
      end
    end

    context 'when @request.thinking is set' do
      let(:thinking_config) { { type: :enabled, budget_tokens: 5000 } }

      let(:request) do
        Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'reason through this' }],
          routing:  { provider: :anthropic, model: 'claude-opus-4-6' },
          thinking: thinking_config
        )
      end

      it 'includes thinking in the chat options' do
        executor = described_class.new(request)
        executor.instance_variable_set(:@resolved_provider, :anthropic)
        executor.instance_variable_set(:@resolved_model, 'claude-opus-4-6')
        opts = executor.send(:native_dispatch_chat_options)
        expect(opts[:thinking]).to eq(thinking_config)
      end
    end
  end

  describe '#call thinking normalization' do
    # SSOT v3: the provider adapter (lex-llm-*) is responsible for stripping
    # inline think tags and building a canonical::Response with text and thinking
    # already separated. The executor's contract is to forward .text as the
    # visible message content and .thinking (if present) as the thinking metadata.
    # This test verifies that invariant via a Phase-1 callable that returns a
    # canonical::Response with both fields correctly populated.
    it 'surfaces thinking content and clean text from a canonical response with thinking' do
      canonical = Legion::Extensions::Llm::Canonical
      thinking_obj = canonical::Thinking.new(
        content:   'The user said "hello".',
        signature: nil,
        metadata:  {}
      )
      usage = canonical::Usage.new(
        input_tokens: 10, output_tokens: 5,
        cache_read_tokens: 0, cache_write_tokens: 0, thinking_tokens: 0, units: {}, metadata: {}
      )
      provider_response = canonical::Response.new(
        text:        'Hello! How can I help you today?',
        thinking:    thinking_obj,
        tool_calls:  [],
        usage:       usage,
        stop_reason: :end_turn,
        model:       'qwen3.6-27b',
        routing:     {},
        metadata:    {}
      )

      callable = Class.new do
        # 0.8.0 callable contract: positional messages (the real boundary shape).
        define_method(:chat) do |messages, model:, **|
          _ = [messages, model]
          provider_response
        end
        define_method(:normalize_dispatch_error) do |error:|
          Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: :provider_error, reason: error.message)
        end
        define_method(:disconnect) { nil }
      end.new

      # SSOT v3: publish via Phase-1 Registry so RoutingSession selects the lane.
      SsotV3SnapshotFactory.activate(
        provider_family: 'vllm',
        instance_id:     'primary',
        callable:        callable,
        drafts:          [SsotV3SnapshotFactory.offering_draft(
          model: 'qwen3.6-27b', tier: :local, supported: %i[chat], context: 200_000
        )]
      )

      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        routing:  { provider: :vllm, model: 'qwen3.6-27b' }
      )
      Legion::Settings[:llm][:fleet][:dispatch][:enabled] = false

      response = described_class.new(request).call

      expect(response.message[:content]).to eq('Hello! How can I help you today?')
      expect(response.thinking).to include(content: 'The user said "hello".')
    end
  end
end
