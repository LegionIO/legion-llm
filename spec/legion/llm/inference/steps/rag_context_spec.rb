# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'

RSpec.describe Legion::LLM::Inference::Steps::RagContext do
  let(:klass) do
    Class.new do
      include Legion::LLM::Inference::Steps::RagContext

      attr_accessor :request, :enrichments, :timeline, :warnings

      def initialize(request)
        @request = request
        @enrichments = {}
        @timeline = Legion::LLM::Inference::Timeline.new
        @warnings = []
      end
    end
  end

  before do
    Legion::Settings[:llm][:rag] = {
      enabled:                       true,
      full_limit:                    10,
      compact_limit:                 5,
      min_confidence:                0.5,
      utilization_compact_threshold: 0.7,
      utilization_skip_threshold:    0.9,
      trivial_max_chars:             20,
      trivial_patterns:              %w[hello hi hey ping pong test ok okay yes no thanks thank],
      exclude_source_agents:         []
    }
  end

  describe '#select_context_strategy' do
    it 'returns :rag when utilization is low (plenty of room)' do
      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.2)).to eq(:rag)
    end

    it 'returns :rag_compact when utilization is high' do
      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.8)).to eq(:rag_compact)
    end

    it 'returns :none when utilization exceeds skip threshold' do
      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.95)).to eq(:none)
    end

    it 'respects explicit strategy override' do
      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'hello' }],
        context_strategy: :none
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.5)).to eq(:none)
    end

    it 'uses custom thresholds from settings' do
      Legion::Settings[:llm][:rag][:utilization_compact_threshold] = 0.5
      Legion::Settings[:llm][:rag][:utilization_skip_threshold] = 0.6

      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'query' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      # 0.55 is above compact (0.5) but below skip (0.6)
      expect(step.send(:select_context_strategy, utilization: 0.55)).to eq(:rag_compact)
      # 0.65 is above skip (0.6)
      expect(step.send(:select_context_strategy, utilization: 0.65)).to eq(:none)
    end

    it 'uses threshold settings via set_prop' do
      merge_llm_settings({
                           rag: {
                             utilization_compact_threshold: 0.4,
                             utilization_skip_threshold:    0.8
                           }
                         })

      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'query' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.5)).to eq(:rag_compact)
      expect(step.send(:select_context_strategy, utilization: 0.85)).to eq(:none)
    end
  end

  describe '#trivial_query?' do
    it 'detects trivial greetings' do
      request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'hello' }])
      step = klass.new(request)
      expect(step.send(:trivial_query?, 'hello')).to be true
      expect(step.send(:trivial_query?, 'ping')).to be true
      expect(step.send(:trivial_query?, 'Hi')).to be true
      expect(step.send(:trivial_query?, 'OK!')).to be true
    end

    it 'does not flag real questions as trivial' do
      request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'what is pgvector?' }])
      step = klass.new(request)
      expect(step.send(:trivial_query?, 'what is pgvector?')).to be false
      expect(step.send(:trivial_query?, 'how do I configure RAG?')).to be false
    end

    it 'does not flag messages longer than trivial_max_chars' do
      request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'hello world how are you today' }])
      step = klass.new(request)
      expect(step.send(:trivial_query?, 'hello world how are you today')).to be false
    end

    it 'uses custom trivial patterns from settings' do
      Legion::Settings[:llm][:rag][:trivial_patterns] = %w[foo bar]
      Legion::Settings[:llm][:rag][:trivial_max_chars] = 10

      request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'foo' }])
      step = klass.new(request)
      expect(step.send(:trivial_query?, 'foo')).to be true
      expect(step.send(:trivial_query?, 'multi word query longer than max')).to be false
    end

    it 'uses trivial pattern settings via set_prop' do
      merge_llm_settings({
                           rag: {
                             trivial_patterns:  %w[foo bar],
                             trivial_max_chars: 10
                           }
                         })

      request = Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'foo' }])
      step = klass.new(request)
      expect(step.send(:trivial_query?, 'foo')).to be true
      expect(step.send(:trivial_query?, 'multi word query longer than max')).to be false
    end
  end

  describe '#step_rag_context' do
    context 'when retrieved entries contain private knowledge' do
      let(:private_values) { %w[PRIVATE_CONTENT_MARKER PRIVATE_RAW_MARKER PRIVATE_CONTEXT_MARKER PRIVATE_METADATA_MARKER PRIVATE_TAG_MARKER] }
      let(:entries) do
        entry = {
          id:           'apollo-entry-42',
          content_type: 'fact',
          confidence:   0.8754,
          distance:     0.1234,
          content:      private_values[0],
          raw_content:  private_values[1],
          context:      { source: private_values[2] },
          metadata:     { description: private_values[3] },
          tags:         [private_values[4]]
        }
        [entry.freeze, entry.transform_keys(&:to_s).merge('id' => 'apollo-entry-43').freeze]
      end
      let(:output) { StringIO.new }
      let(:logger) { Logger.new(output, level: level, formatter: proc { |severity, _time, _progname, message| "#{severity}: #{message}\n" }) }
      let(:request) do
        Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'what is pgvector?' }], context_strategy: :rag
        )
      end
      let(:step) { klass.new(request) }

      before do
        apollo_runner = double('Knowledge', retrieve_relevant: { success: true, entries: entries, count: entries.size })
        stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)
        allow(step).to receive(:log).and_return(logger)
      end

      [Logger::DEBUG, Logger::INFO].each do |log_level|
        context "with log level #{Logger::SEV_LABEL[log_level]}" do
          let(:level) { log_level }

          it 'keeps private data in enrichment and out of emitted logs' do
            step.step_rag_context

            expect(step.warnings).to be_empty
            expect(step.enrichments['rag:context_retrieval'][:data][:entries]).to eq(entries)
            private_values.each { |value| expect(output.string).not_to include(value) }
            expect(output.string).not_to include('ANY:')
            expect(output.string).to include('entry_count=2')
          end

          it 'emits entry IDs and allowlisted diagnostics only at DEBUG' do
            step.step_rag_context

            if log_level == Logger::DEBUG
              %w[apollo-entry-42 apollo-entry-43].each do |id|
                entry_log = output.string.lines.find { |line| line.include?(id) }
                expect(entry_log).to start_with('DEBUG:')
                expect(entry_log).to include('content_type=fact', 'confidence=0.875', 'distance=0.123',
                                             "content_chars=#{private_values[0].length}", "request_id=#{request.id}")
              end
            else
              expect(output.string).not_to include('apollo-entry-42', 'apollo-entry-43')
            end
          end
        end
      end
    end

    it 'skips when strategy is :none via explicit override' do
      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :none
      )
      step = klass.new(request)
      step.step_rag_context
      expect(step.enrichments).not_to have_key('rag:context_retrieval')
    end

    it 'skips trivial queries' do
      apollo_runner = double('Knowledge')
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'hello' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      step.step_rag_context
      expect(step.enrichments).not_to have_key('rag:context_retrieval')
    end

    it 'fires RAG on short but substantive queries' do
      apollo_runner = double('Knowledge')
      apollo_result = {
        success: true,
        entries: [{ id: 'e1', content: 'pgvector info', content_type: 'fact', confidence: 0.85 }],
        count:   1
      }
      allow(apollo_runner).to receive(:retrieve_relevant).and_return(apollo_result)
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      step.step_rag_context
      expect(step.enrichments).to have_key('rag:context_retrieval')
    end

    it 'skips when rag is disabled in settings' do
      Legion::Settings[:llm][:rag][:enabled] = false

      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      step.step_rag_context
      expect(step.enrichments).not_to have_key('rag:context_retrieval')
    end

    it 'honors rag.enabled = true after being set to false (bidirectional)' do
      Legion::Settings[:llm][:rag][:enabled] = false

      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :rag
      )
      step = klass.new(request)
      step.step_rag_context
      expect(step.enrichments).not_to have_key('rag:context_retrieval')

      Legion::Settings[:llm][:rag][:enabled] = true

      apollo_runner = double('Knowledge')
      allow(apollo_runner).to receive(:retrieve_relevant).and_return({
                                                                       success: true, entries: [], count: 0
                                                                     })
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

      step2 = klass.new(request)
      step2.step_rag_context
      expect(step2.warnings).not_to include(match(/disabled/))
    end

    it 'skips when rag is disabled in string-keyed settings' do
      allow(Legion::LLM).to receive(:settings).and_return({ 'rag' => { 'enabled' => false } })

      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      step.step_rag_context
      expect(step.enrichments).not_to have_key('rag:context_retrieval')
    end

    it 'populates enrichments when Apollo returns results' do
      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :rag
      )

      apollo_runner = double('Knowledge')
      allow(apollo_runner).to receive(:retrieve_relevant).and_return({
                                                                       success: true,
                                                                       entries: [
                                                                         { id: 'e1', content: 'pgvector is...', content_type: 'fact', confidence: 0.85 },
                                                                         { id: 'e2', content: 'cosine distance...', content_type: 'concept', confidence: 0.72 }
                                                                       ],
                                                                       count:   2
                                                                     })
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

      step = klass.new(request)
      step.step_rag_context
      expect(step.enrichments).to have_key('rag:context_retrieval')
      expect(step.enrichments['rag:context_retrieval'][:data][:entries].size).to eq(2)
    end

    it 'passes configurable limits and confidence to Apollo' do
      Legion::Settings[:llm][:rag][:full_limit] = 15
      Legion::Settings[:llm][:rag][:min_confidence] = 0.3

      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :rag
      )

      apollo_runner = double('Knowledge')
      allow(apollo_runner).to receive(:retrieve_relevant)
        .with(query: 'what is pgvector?', limit: 15, min_confidence: 0.3)
        .and_return({ success: true, entries: [], count: 0 })
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

      step = klass.new(request)
      step.step_rag_context
    end

    it 'extracts text from structured user content before querying Apollo' do
      request = Legion::LLM::Inference::Request.build(
        messages:         [
          {
            role:    :user,
            content: [
              { type: 'text', text: 'okay updated some things, try again' }
            ]
          }
        ],
        context_strategy: :rag
      )

      apollo_runner = double('Knowledge')
      allow(apollo_runner).to receive(:retrieve_relevant)
        .with(query: 'okay updated some things, try again', limit: 10, min_confidence: 0.5)
        .and_return({ success: true, entries: [], count: 0 })
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

      step = klass.new(request)
      step.step_rag_context

      expect(step.warnings).to be_empty
    end

    it 'retrieves scoped archived conversation history when a conversation_id is present' do
      Legion::Settings[:llm][:rag][:conversation_history_enabled] = true
      request = Legion::LLM::Inference::Request.build(
        conversation_id:  'conv-rag-history',
        messages:         [{ role: :user, content: 'what did we decide about pgvector?' }],
        context_strategy: :rag
      )

      apollo_runner = double('Knowledge')
      allow(apollo_runner).to receive(:retrieve_relevant)
        .with(query: 'what did we decide about pgvector?', limit: 10, min_confidence: 0.5)
        .and_return({ success: true, entries: [], count: 0 })
      allow(apollo_runner).to receive(:retrieve_relevant)
        .with(hash_including(tags: include('conversation:conv-rag-history'), domain: 'conversation_history'))
        .and_return({
                      success: true,
                      entries: [{ id: 'hist-1', content: 'Prior decision: use pgvector cosine distance', content_type: 'conversation_turn' }],
                      count:   1
                    })
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

      step = klass.new(request)
      step.step_rag_context

      entries = step.enrichments['rag:context_retrieval'][:data][:entries]
      expect(entries.map { |entry| entry[:content] }).to include('Prior decision: use pgvector cosine distance')
    end

    it 'caps retrieval limit with GAIA advisory context window' do
      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :rag
      )

      apollo_runner = double('Knowledge')
      allow(apollo_runner).to receive(:retrieve_relevant)
        .with(query: 'what is pgvector?', limit: 2, min_confidence: 0.5)
        .and_return({ success: true, entries: [], count: 0 })
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

      step = klass.new(request)
      step.enrichments['gaia:advisory'] = { data: { context_window: { limit: 2 } } }
      step.step_rag_context
    end

    it 'ignores missing GAIA advisory context window values without exception handling' do
      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :rag
      )

      apollo_runner = double('Knowledge')
      allow(apollo_runner).to receive(:retrieve_relevant)
        .with(query: 'what is pgvector?', limit: 10, min_confidence: 0.5)
        .and_return({ success: true, entries: [], count: 0 })
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

      step = klass.new(request)
      step.enrichments['gaia:advisory'] = { data: { context_window: { rag: nil } } }

      expect(step).not_to receive(:handle_exception)
      step.step_rag_context
    end

    it 'uses compact_limit for rag_compact strategy' do
      Legion::Settings[:llm][:rag][:compact_limit] = 3

      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :rag_compact
      )

      apollo_runner = double('Knowledge')
      allow(apollo_runner).to receive(:retrieve_relevant)
        .with(query: 'what is pgvector?', limit: 3, min_confidence: 0.5)
        .and_return({ success: true, entries: [], count: 0 })
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

      step = klass.new(request)
      step.step_rag_context
    end

    it 'degrades gracefully when Apollo unavailable' do
      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :rag
      )
      hide_const('Legion::Extensions::Apollo') if defined?(Legion::Extensions::Apollo)

      step = klass.new(request)
      step.step_rag_context
      expect(step.enrichments).not_to have_key('rag:context_retrieval')
      expect(step.warnings).to include(match(/Apollo unavailable/))
    end

    it 'records timeline event' do
      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :rag
      )

      apollo_runner = double('Knowledge')
      allow(apollo_runner).to receive(:retrieve_relevant).and_return({
                                                                       success: true, entries: [], count: 0
                                                                     })
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

      step = klass.new(request)
      step.step_rag_context
      keys = step.timeline.events.map { |e| e[:key] }
      expect(keys).to include('rag:context_retrieval')
    end
  end

  describe '#positive_integer' do
    let(:step) do
      klass.new(Legion::LLM::Inference::Request.build(messages: [{ role: :user, content: 'hi' }]))
    end

    it 'returns nil for nil without raising TypeError (#122)' do
      expect(step.send(:positive_integer, nil)).to be_nil
    end

    it 'returns nil for empty string without raising (#122)' do
      expect(step.send(:positive_integer, '')).to be_nil
    end

    it 'returns the integer for a valid positive value' do
      expect(step.send(:positive_integer, 42)).to eq(42)
    end

    it 'returns nil for zero' do
      expect(step.send(:positive_integer, 0)).to be_nil
    end

    it 'returns nil for a non-numeric string' do
      expect(step.send(:positive_integer, 'abc')).to be_nil
    end
  end

  describe '#apollo_available? with Legion::Apollo' do
    it 'returns true when Legion::Apollo is started' do
      apollo = Module.new do
        def self.started? = true
      end
      stub_const('Legion::Apollo', apollo)
      hide_const('Legion::Extensions::Apollo') if defined?(Legion::Extensions::Apollo)

      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'what is pgvector?' }]
      )
      step = klass.new(request)
      expect(step.send(:apollo_available?)).to be true
    end
  end

  describe '#apollo_retrieve via Legion::Apollo path' do
    it 'calls Legion::Apollo.retrieve with scope: :all when Legion::Apollo is started' do
      apollo = Module.new do
        def self.started? = true

        def self.retrieve(**)
          { success: true, entries: [{ id: 1, content: 'fact', confidence: 0.8 }], count: 1 }
        end
      end
      stub_const('Legion::Apollo', apollo)
      hide_const('Legion::Extensions::Apollo') if defined?(Legion::Extensions::Apollo)

      request = Legion::LLM::Inference::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :rag
      )
      step = klass.new(request)

      expect(Legion::Apollo).to receive(:retrieve).with(
        hash_including(
          scope: :all,
          text:  a_string_including('what is pgvector?'),
          limit: kind_of(Integer)
        )
      ).and_call_original

      step.step_rag_context
      expect(step.enrichments).to have_key('rag:context_retrieval')
    end
  end
end
