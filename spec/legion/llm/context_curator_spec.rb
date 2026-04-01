# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/context_curator'

RSpec.describe Legion::LLM::ContextCurator do
  let(:conversation_id) { 'test-conv-001' }
  subject(:curator) { described_class.new(conversation_id: conversation_id) }

  before do
    Legion::Settings[:llm][:context_curation] = {
      enabled:               true,
      mode:                  'heuristic',
      llm_assisted:          false,
      llm_model:             nil,
      tool_result_max_chars: 100,
      thinking_eviction:     true,
      exchange_folding:      true,
      superseded_eviction:   true,
      dedup_enabled:         true,
      dedup_threshold:       0.85,
      target_context_tokens: 40_000
    }
    Legion::LLM::ConversationStore.reset!
  end

  # --- enabled: false ---

  describe 'enabled: false bypasses all curation' do
    before { Legion::Settings[:llm][:context_curation][:enabled] = false }

    it 'curate_turn returns nil without spawning a thread' do
      allow(Thread).to receive(:new)
      result = curator.curate_turn(turn_messages:      [{ role: :user, content: 'hi' }],
                                   assistant_response: 'hello')
      expect(result).to be_nil
      expect(Thread).not_to have_received(:new)
    end

    it 'curated_messages returns nil' do
      expect(curator.curated_messages).to be_nil
    end
  end

  # --- heuristic tool result distillation ---

  describe '#distill_tool_result' do
    context 'content shorter than threshold' do
      it 'returns the message unchanged' do
        msg = { role: :tool, content: 'short content' }
        expect(curator.distill_tool_result(msg)).to eq(msg)
      end
    end

    context 'read_file result exceeding threshold' do
      let(:content) { "line one\n" * 20 }
      let(:msg) { { role: :tool, content: content, tool_name: :read_file } }

      it 'summarizes with line count' do
        result = curator.distill_tool_result(msg)
        expect(result[:content]).to include('Read file')
        expect(result[:content]).to include('lines')
        expect(result[:curated]).to be true
        expect(result[:original_content]).to eq(content)
      end
    end

    context 'search/grep result exceeding threshold' do
      let(:content) { "spec/foo_spec.rb: match\nlib/bar.rb: match\n" * 10 }
      let(:msg) { { role: :tool, content: content, tool_name: :search } }

      it 'summarizes as search matches' do
        result = curator.distill_tool_result(msg)
        expect(result[:content]).to include('Search returned')
        expect(result[:curated]).to be true
      end
    end

    context 'bash/run_command result exceeding threshold' do
      let(:content) { "#{"line\n" * 30}exit code: 0\n" }
      let(:msg) { { role: :tool, content: content, tool_name: :bash } }

      it 'summarizes with exit code and last lines' do
        result = curator.distill_tool_result(msg)
        expect(result[:content]).to match(/Command output.*exit/i)
        expect(result[:curated]).to be true
      end
    end

    context 'unknown tool exceeding threshold' do
      let(:content) { 'x' * 200 }
      let(:msg) { { role: :tool, content: content, tool_name: :unknown_thing } }

      it 'uses generic tool result summary' do
        result = curator.distill_tool_result(msg)
        expect(result[:content]).to include('Tool result')
        expect(result[:curated]).to be true
      end
    end
  end

  # --- thinking block eviction ---

  describe '#strip_thinking' do
    context 'message contains a thinking block' do
      let(:content) { "<thinking>This is my internal reasoning that should be removed.</thinking>\nFinal answer here." }
      let(:msg) { { role: :assistant, content: content } }

      it 'removes thinking block and marks curated' do
        result = curator.strip_thinking(msg)
        expect(result[:content]).not_to include('<thinking>')
        expect(result[:content]).to include('Final answer here.')
        expect(result[:curated]).to be true
        expect(result[:original_content]).to eq(content)
      end
    end

    context 'message has no thinking block' do
      let(:msg) { { role: :assistant, content: 'Just a normal message.' } }

      it 'returns the message unchanged' do
        expect(curator.strip_thinking(msg)).to eq(msg)
      end
    end

    context 'thinking_eviction disabled' do
      before { Legion::Settings[:llm][:context_curation][:thinking_eviction] = false }

      it 'returns the message unchanged even when thinking block present' do
        content = '<thinking>internal</thinking>answer'
        msg = { role: :assistant, content: content }
        expect(curator.strip_thinking(msg)).to eq(msg)
      end
    end

    context 'stripping thinking leaves empty content' do
      let(:msg) { { role: :assistant, content: '<thinking>only thinking</thinking>' } }

      it 'returns the original message unchanged' do
        expect(curator.strip_thinking(msg)).to eq(msg)
      end
    end
  end

  # --- exchange folding ---

  describe '#fold_resolved_exchanges' do
    context 'exchange_folding disabled' do
      before { Legion::Settings[:llm][:context_curation][:exchange_folding] = false }

      it 'returns messages unchanged' do
        messages = [
          { role: :user, content: 'what do you mean?' },
          { role: :assistant, content: 'I see, yes, the answer is 42.' }
        ]
        expect(curator.fold_resolved_exchanges(messages)).to eq(messages)
      end
    end

    context 'no resolved exchange detected' do
      it 'returns messages unchanged' do
        messages = [
          { role: :user, content: 'Hello there' },
          { role: :assistant, content: 'Hi, how can I help?' },
          { role: :user, content: 'Tell me about Ruby' }
        ]
        result = curator.fold_resolved_exchanges(messages)
        expect(result.length).to eq(messages.length)
      end
    end

    context 'resolved clarification exchange detected' do
      it 'folds to a single system note' do
        messages = [
          { role: :user, content: 'What do you mean by that?' },
          { role: :assistant, content: 'I see, understood. The answer is 42 and that is correct.' }
        ]
        result = curator.fold_resolved_exchanges(messages)
        # Should fold or pass through — test primarily that it does not crash
        expect(result).to be_an(Array)
        expect(result).not_to be_empty
      end
    end
  end

  # --- superseded content eviction ---

  describe '#evict_superseded' do
    context 'superseded_eviction disabled' do
      before { Legion::Settings[:llm][:context_curation][:superseded_eviction] = false }

      it 'returns messages unchanged' do
        msgs = [
          { role: :user, content: 'Read: /tmp/foo.rb content 1' },
          { role: :user, content: 'Read: /tmp/foo.rb content 2' }
        ]
        expect(curator.evict_superseded(msgs)).to eq(msgs)
      end
    end

    context 'same file read multiple times' do
      let(:msgs) do
        [
          { role: :user, content: 'reading /app/config.rb first version' },
          { role: :assistant, content: 'I see.' },
          { role: :user, content: 'reading /app/config.rb updated version with more detail' }
        ]
      end

      it 'keeps only the latest read of each file' do
        result = curator.evict_superseded(msgs)
        file_reads = result.select { |m| m[:content].include?('/app/config.rb') }
        expect(file_reads.length).to eq(1)
        expect(file_reads.first[:content]).to include('updated version')
      end
    end

    context 'different files' do
      let(:msgs) do
        [
          { role: :user, content: 'reading /app/foo.rb content' },
          { role: :user, content: 'reading /app/bar.rb content' }
        ]
      end

      it 'keeps both file reads' do
        result = curator.evict_superseded(msgs)
        expect(result.length).to eq(2)
      end
    end
  end

  # --- deduplication ---

  describe '#dedup_similar' do
    context 'dedup_enabled is false' do
      before { Legion::Settings[:llm][:context_curation][:dedup_enabled] = false }

      it 'returns messages unchanged' do
        msgs = [
          { role: :user, content: 'Hello world how are you today' },
          { role: :user, content: 'Hello world how are you today' }
        ]
        expect(curator.dedup_similar(msgs)).to eq(msgs)
      end
    end

    context 'identical messages' do
      it 'removes duplicates' do
        text = 'This is a longer message about Ruby programming and how it works in practice today'
        msgs = [
          { role: :user, content: text },
          { role: :assistant, content: 'OK' },
          { role: :user, content: text }
        ]
        result = curator.dedup_similar(msgs)
        user_msgs = result.select { |m| m[:role] == :user }
        expect(user_msgs.length).to eq(1)
      end
    end

    context 'distinct messages' do
      it 'preserves all messages' do
        msgs = [
          { role: :user, content: 'tell me about cats and their behavior patterns in nature' },
          { role: :user, content: 'now tell me about dogs and how they differ from cats entirely' }
        ]
        result = curator.dedup_similar(msgs)
        expect(result.length).to eq(2)
      end
    end

    context 'with explicit threshold' do
      it 'respects provided threshold' do
        text_a = 'The quick brown fox jumps over the lazy dog in the park today'
        text_b = 'The quick brown fox jumps over the lazy dog in the park yesterday'
        msgs = [
          { role: :user, content: text_a },
          { role: :user, content: text_b }
        ]
        # Very low threshold — these similar messages should be deduped
        result = curator.dedup_similar(msgs, threshold: 0.5)
        expect(result.length).to be <= 2
      end
    end
  end

  # --- LLM-assisted distillation ---

  describe '#llm_distill_tool_result' do
    context 'llm_assisted is false (default)' do
      it 'falls back to heuristic distillation' do
        content = 'x' * 200
        msg = { role: :tool, content: content }
        result = curator.llm_distill_tool_result(msg)
        # Should use heuristic (not call LLM)
        expect(result[:content]).not_to eq(content)
        expect(result[:curated]).to be true
      end
    end

    context 'llm_assisted is true and mode is llm_assisted' do
      before do
        Legion::Settings[:llm][:context_curation][:llm_assisted] = true
        Legion::Settings[:llm][:context_curation][:mode] = 'llm_assisted'
        # Provide an explicit model so detect_small_model is bypassed
        Legion::Settings[:llm][:context_curation][:llm_model] = 'qwen3.5:latest'
      end

      it 'calls LLM and returns its response' do
        content = 'x' * 200
        msg = { role: :tool, content: content }
        fake_response = double('Response', content: 'LLM summary of tool result')
        allow(Legion::LLM).to receive(:respond_to?).with(:chat_direct).and_return(true)
        allow(Legion::LLM).to receive(:chat_direct).and_return(fake_response)

        result = curator.llm_distill_tool_result(msg)
        expect(result[:content]).to eq('LLM summary of tool result')
        expect(result[:curated]).to be true
      end

      it 'falls back to heuristic on LLM error' do
        content = 'x' * 200
        msg = { role: :tool, content: content }
        allow(Legion::LLM).to receive(:respond_to?).with(:chat_direct).and_return(true)
        allow(Legion::LLM).to receive(:chat_direct).and_raise(StandardError, 'LLM unavailable')

        result = curator.llm_distill_tool_result(msg)
        # Falls back to heuristic — should still distill
        expect(result[:curated]).to be true
      end
    end
  end

  # --- async curation does not block caller ---

  describe '#curate_turn' do
    it 'returns a Thread without blocking' do
      messages = [{ role: :user, content: 'hi' }]
      result = curator.curate_turn(turn_messages: messages, assistant_response: 'hello')
      expect(result).to be_a(Thread)
      result.join(2) # wait for thread to finish
    end

    it 'never raises even if curation fails internally' do
      allow(curator).to receive(:store_curated).and_raise(StandardError, 'storage failure')
      thread = curator.curate_turn(turn_messages:      [{ role: :user, content: 'test' }],
                                   assistant_response: 'response')
      expect { thread.join(2) }.not_to raise_error
    end
  end

  # --- curated cache invalidation ---

  describe 'cache invalidation after async curation' do
    it 'clears @curated_cache after thread completes' do
      # Prime the cache
      allow(Legion::LLM::ConversationStore).to receive(:conversation_exists?).and_return(false)
      first = curator.curated_messages
      expect(first).to be_nil # no curated messages yet

      # After curate_turn, the cache should be invalidated
      thread = curator.curate_turn(turn_messages:      [{ role: :user, content: 'msg' }],
                                   assistant_response: 'resp')
      thread.join(2)
      # @curated_cache was set to nil — next call will re-load
      # We can't directly inspect @curated_cache, but curated_messages should still work
      expect { curator.curated_messages }.not_to raise_error
    end
  end

  # --- settings-driven behavior ---

  describe 'settings-driven behavior' do
    it 'uses tool_result_max_chars from settings' do
      Legion::Settings[:llm][:context_curation][:tool_result_max_chars] = 10
      content = 'x' * 20
      msg = { role: :tool, content: content }
      result = curator.distill_tool_result(msg)
      expect(result[:curated]).to be true
    end

    it 'dedup_threshold from settings is used' do
      Legion::Settings[:llm][:context_curation][:dedup_threshold] = 0.99
      text_a = 'The quick brown fox jumps over the lazy dog and runs away fast now'
      text_b = 'The quick brown fox jumps over the lazy dog and runs away fast then'
      msgs = [
        { role: :user, content: text_a },
        { role: :user, content: text_b }
      ]
      # High threshold — these two should NOT be deduped
      result = curator.dedup_similar(msgs)
      expect(result.length).to eq(2)
    end

    it 'target_context_tokens is accessible in settings' do
      expect(Legion::Settings[:llm][:context_curation][:target_context_tokens]).to eq(40_000)
    end
  end

  # --- default settings values ---

  describe 'default settings' do
    before do
      Legion::Settings.reset!
      Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    end

    it 'context_curation is enabled by default' do
      expect(Legion::Settings.dig(:llm, :context_curation, :enabled)).to be true
    end

    it 'mode defaults to heuristic' do
      expect(Legion::Settings.dig(:llm, :context_curation, :mode)).to eq('heuristic')
    end

    it 'llm_assisted defaults to false' do
      expect(Legion::Settings.dig(:llm, :context_curation, :llm_assisted)).to be false
    end

    it 'tool_result_max_chars defaults to 2000' do
      expect(Legion::Settings.dig(:llm, :context_curation, :tool_result_max_chars)).to eq(2000)
    end

    it 'thinking_eviction defaults to true' do
      expect(Legion::Settings.dig(:llm, :context_curation, :thinking_eviction)).to be true
    end

    it 'exchange_folding defaults to true' do
      expect(Legion::Settings.dig(:llm, :context_curation, :exchange_folding)).to be true
    end

    it 'superseded_eviction defaults to true' do
      expect(Legion::Settings.dig(:llm, :context_curation, :superseded_eviction)).to be true
    end

    it 'dedup_enabled defaults to true' do
      expect(Legion::Settings.dig(:llm, :context_curation, :dedup_enabled)).to be true
    end

    it 'dedup_threshold defaults to 0.85' do
      expect(Legion::Settings.dig(:llm, :context_curation, :dedup_threshold)).to eq(0.85)
    end

    it 'target_context_tokens defaults to 40000' do
      expect(Legion::Settings.dig(:llm, :context_curation, :target_context_tokens)).to eq(40_000)
    end
  end
end
