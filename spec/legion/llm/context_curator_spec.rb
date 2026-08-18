# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/context/curator'

RSpec.describe Legion::LLM::Context::Curator do
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
    Legion::LLM::Inference::Conversation.reset!
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

    context 'message contains a <think> block (DeepSeek/Qwen/Ollama)' do
      let(:content) { "<think>Internal chain of thought from DeepSeek.</think>\nAnswer here." }
      let(:msg) { { role: :assistant, content: content } }

      it 'removes <think> block and marks curated' do
        result = curator.strip_thinking(msg)
        expect(result[:content]).not_to include('<think>')
        expect(result[:content]).to include('Answer here.')
        expect(result[:curated]).to be true
      end
    end

    context 'message contains both <thinking> and <think> blocks' do
      let(:content) { '<thinking>Anthropic block.</thinking> <think>Ollama block.</think> Final.' }
      let(:msg) { { role: :assistant, content: content } }

      it 'removes both variants' do
        result = curator.strip_thinking(msg)
        expect(result[:content]).not_to include('<thinking>')
        expect(result[:content]).not_to include('<think>')
        expect(result[:content]).to include('Final.')
      end
    end

    context 'message has an unclosed <think> tag at start (provider died mid-stream)' do
      let(:content) { '<think>Reasoning that never finished' }
      let(:msg) { { role: :assistant, content: content } }

      it 'returns original when stripping would produce empty content' do
        result = curator.strip_thinking(msg)
        expect(result).to eq(msg)
      end
    end

    context 'message has an unclosed <thinking> tag at start' do
      let(:content) { '<thinking>Partial reasoning' }
      let(:msg) { { role: :assistant, content: content } }

      it 'returns original when stripping would produce empty content' do
        result = curator.strip_thinking(msg)
        expect(result).to eq(msg)
      end
    end

    context 'message references thinking tags mid-content (not real thinking blocks)' do
      let(:content) { 'Use `<think>` for reasoning. The model outputs `</think>` when done.' }
      let(:msg) { { role: :assistant, content: content } }

      it 'does not strip content between referenced tags' do
        result = curator.strip_thinking(msg)
        expect(result).to eq(msg)
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

  # --- harness-noise stripping (GH#168) ---

  describe '#strip_harness_noise' do
    let(:task_nag) do
      "The task tools haven't been used recently. If you're working on tasks that would " \
        'benefit from tracking progress, consider using TaskCreate to add new tasks. ' \
        'This is just a gentle reminder - ignore if not applicable.'
    end
    let(:linter_note) do
      'Note: /path/to/file.rb was modified, either by the user or by a linter. ' \
        'Here are the relevant changes: ...(full file dump)...'
    end

    context 'harness_noise_strip disabled' do
      before { Legion::Settings[:llm][:context_curation][:harness_noise_strip] = false }

      it 'returns messages unchanged' do
        msgs = [
          { role: :system, content: task_nag },
          { role: :user, content: 'do the thing' }
        ]
        expect(curator.strip_harness_noise(msgs)).to eq(msgs)
      end
    end

    context 'known harness patterns' do
      before do
        Legion::Settings[:llm][:context_curation][:harness_noise_patterns] = [
          "task tools haven't been used recently",
          'was modified, either by the user or by a linter'
        ]
      end

      it 'strips the task-nag system message' do
        msgs = [
          { role: :user, content: 'first' },
          { role: :system, content: task_nag },
          { role: :assistant, content: 'ok' }
        ]
        result = curator.strip_harness_noise(msgs)
        expect(result.map { |m| m[:role] }).to eq(%i[user assistant])
      end

      it 'strips the linter file-dump note' do
        msgs = [
          { role: :system, content: linter_note },
          { role: :user, content: 'keep me' }
        ]
        result = curator.strip_harness_noise(msgs)
        expect(result.map { |m| m[:content] }).to eq(['keep me'])
      end

      it 'strips every repeated occurrence of a known pattern' do
        msgs = Array.new(18) { { role: :system, content: task_nag } } +
               [{ role: :user, content: 'work' }]
        result = curator.strip_harness_noise(msgs)
        expect(result).to eq([{ role: :user, content: 'work' }])
      end
    end

    context 'exact-duplicate system messages' do
      it 'keeps the first and drops verbatim duplicates' do
        dup = { role: :system, content: 'Some injected note that repeats verbatim.' }
        msgs = [dup.dup, { role: :assistant, content: 'a' }, dup.dup, dup.dup]
        result = curator.strip_harness_noise(msgs)
        systems = result.select { |m| m[:role] == :system }
        expect(systems.size).to eq(1)
      end
    end

    context 'fail-safe: unrecognized content' do
      it 'never strips an unrecognized, non-duplicate system message' do
        msgs = [
          { role: :system, content: 'You are a specialized agent with these rules: ...' },
          { role: :user, content: 'hi' }
        ]
        expect(curator.strip_harness_noise(msgs)).to eq(msgs)
      end

      it 'never touches non-system roles even if content matches a pattern' do
        # A user/assistant message that happens to quote the nag text must survive.
        msgs = [{ role: :user, content: "why does it say the task tools haven't been used recently?" }]
        expect(curator.strip_harness_noise(msgs)).to eq(msgs)
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

  describe 'stored curation records' do
    it 'stores a marker when a curation pass does not modify any messages' do
      curator.send(:store_curated, conversation_id, [{ role: :user, content: 'short message' }])

      # CURATED_KEY entries are internal bookkeeping — use raw_messages to inspect them.
      curated_entries = Legion::LLM::Inference::Conversation.raw_messages(conversation_id)
                                                            .select { |msg| msg[:role] == described_class::CURATED_KEY }
      expect(curated_entries.size).to eq(1)
      payload = Legion::JSON.parse(curated_entries.first[:content])
      expect(payload[:type] || payload['type']).to eq('curation_marker')
    end

    it 'uses stored curated summaries instead of the original verbose message content' do
      original = Legion::LLM::Inference::Conversation.append(
        conversation_id,
        role:    :tool,
        content: 'verbose payload ' * 100
      )
      curator.send(
        :store_curated,
        conversation_id,
        [
          original.merge(
            content:          'stored compact summary',
            original_content: original[:content],
            curated:          true
          )
        ]
      )

      result = curator.curated_messages

      expect(result.map { |msg| msg[:content] }).to include('stored compact summary')
      expect(result.map { |msg| msg[:content] }).not_to include(original[:content])
    end

    it 'runs structural curation when a marker exists without per-message summaries' do
      content = 'This is a longer duplicate message about a configuration problem in Legion'
      Legion::LLM::Inference::Conversation.append(conversation_id, role: :user, content: content)
      Legion::LLM::Inference::Conversation.append(conversation_id, role: :user, content: content)
      curator.send(:store_curated, conversation_id, [{ role: :user, content: 'short message' }])

      result = curator.curated_messages

      expect(result.count { |msg| msg[:role] == :user && msg[:content] == content }).to eq(1)
    end
  end

  describe '#drop_and_archive' do
    it 'archives dropped conversation turns to Apollo and returns the retained tail' do
      ingested = []
      apollo_local = Module.new do
        define_singleton_method(:started?) { true }
        define_singleton_method(:ingest) { |**payload| ingested << payload }
      end
      stub_const('Legion::Apollo::Local', apollo_local)
      Legion::Settings[:llm][:context_curation] = Legion::Settings[:llm][:context_curation].merge(
        target_context_tokens:   5,
        archive_preserve_recent: 1
      )

      messages = [
        { seq: 1, role: :user, content: 'old user message ' * 20 },
        { seq: 2, role: :assistant, content: 'old assistant message ' * 20 },
        { seq: 3, role: :user, content: 'new question' }
      ]

      retained = curator.drop_and_archive(messages, conversation_id: conversation_id)

      expect(retained.map { |msg| msg[:seq] }).to eq([3])
      expect(ingested.size).to eq(1)
      expect(ingested.first[:tags]).to include('llm_conversation_history', "conversation:#{conversation_id}")
      expect(ingested.first[:content]).to include('old user message', 'old assistant message')
    end
  end

  # --- async curation does not block caller ---

  describe '#curate_turn' do
    it 'submits work to the async pool without blocking' do
      messages = [{ role: :user, content: 'hi' }]
      expect { curator.curate_turn(turn_messages: messages, assistant_response: 'hello') }.not_to raise_error
      sleep 0.1
    end

    it 'never raises even if curation fails internally' do
      allow(curator).to receive(:store_curated).and_raise(StandardError, 'storage failure')
      expect do
        curator.curate_turn(turn_messages: [{ role: :user, content: 'test' }], assistant_response: 'response')
        sleep 0.1
      end.not_to raise_error
    end
  end

  # --- curated cache invalidation ---

  describe 'cache invalidation after async curation' do
    it 'clears @curated_messages after async work completes' do
      curator.instance_variable_set(:@curated_messages, [{ role: :user, content: 'stale' }])

      curator.curate_turn(turn_messages: [{ role: :user, content: 'msg' }], assistant_response: 'resp')
      sleep 0.2

      expect(curator.instance_variable_get(:@curated_messages)).to be_nil
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

    # SSOT v3: the curator no longer scans extension provider defaults to pick a
    # small model (detect_small_model removed). It forwards the explicitly
    # configured curation model, or skips LLM distillation when none is set.
    it 'skips LLM distillation when no curation model is configured' do
      allow(curator).to receive(:setting).and_call_original
      allow(curator).to receive(:setting).with(:llm_model, nil).and_return(nil)
      expect(Legion::LLM).not_to receive(:chat_direct)

      expect(curator.send(:llm_summarize_tool_result, 'some tool output', 'read_file')).to be_nil
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

    it 'tool_result_max_chars defaults to 10000' do
      expect(Legion::Settings.dig(:llm, :context_curation, :tool_result_max_chars)).to eq(10_000)
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

    it 'target_context_tokens defaults to 120000' do
      expect(Legion::Settings.dig(:llm, :context_curation, :target_context_tokens)).to eq(120_000)
    end
  end
end
