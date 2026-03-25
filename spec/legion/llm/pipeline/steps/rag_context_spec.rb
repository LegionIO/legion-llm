# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::RagContext do
  let(:klass) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::RagContext

      attr_accessor :request, :enrichments, :timeline, :warnings

      def initialize(request)
        @request = request
        @enrichments = {}
        @timeline = Legion::LLM::Pipeline::Timeline.new
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
      trivial_patterns:              %w[hello hi hey ping pong test ok okay yes no thanks thank]
    }
  end

  describe '#select_context_strategy' do
    it 'returns :rag when utilization is low (plenty of room)' do
      request = Legion::LLM::Pipeline::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.2)).to eq(:rag)
    end

    it 'returns :rag_compact when utilization is high' do
      request = Legion::LLM::Pipeline::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.8)).to eq(:rag_compact)
    end

    it 'returns :none when utilization exceeds skip threshold' do
      request = Legion::LLM::Pipeline::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.95)).to eq(:none)
    end

    it 'respects explicit strategy override' do
      request = Legion::LLM::Pipeline::Request.build(
        messages:         [{ role: :user, content: 'hello' }],
        context_strategy: :none
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.5)).to eq(:none)
    end

    it 'uses custom thresholds from settings' do
      Legion::Settings[:llm][:rag][:utilization_compact_threshold] = 0.5
      Legion::Settings[:llm][:rag][:utilization_skip_threshold] = 0.6

      request = Legion::LLM::Pipeline::Request.build(
        messages:         [{ role: :user, content: 'query' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      # 0.55 is above compact (0.5) but below skip (0.6)
      expect(step.send(:select_context_strategy, utilization: 0.55)).to eq(:rag_compact)
      # 0.65 is above skip (0.6)
      expect(step.send(:select_context_strategy, utilization: 0.65)).to eq(:none)
    end
  end

  describe '#trivial_query?' do
    it 'detects trivial greetings' do
      request = Legion::LLM::Pipeline::Request.build(messages: [{ role: :user, content: 'hello' }])
      step = klass.new(request)
      expect(step.send(:trivial_query?, 'hello')).to be true
      expect(step.send(:trivial_query?, 'ping')).to be true
      expect(step.send(:trivial_query?, 'Hi')).to be true
      expect(step.send(:trivial_query?, 'OK!')).to be true
    end

    it 'does not flag real questions as trivial' do
      request = Legion::LLM::Pipeline::Request.build(messages: [{ role: :user, content: 'what is pgvector?' }])
      step = klass.new(request)
      expect(step.send(:trivial_query?, 'what is pgvector?')).to be false
      expect(step.send(:trivial_query?, 'how do I configure RAG?')).to be false
    end

    it 'does not flag messages longer than trivial_max_chars' do
      request = Legion::LLM::Pipeline::Request.build(messages: [{ role: :user, content: 'hello world how are you today' }])
      step = klass.new(request)
      expect(step.send(:trivial_query?, 'hello world how are you today')).to be false
    end

    it 'uses custom trivial patterns from settings' do
      Legion::Settings[:llm][:rag][:trivial_patterns] = %w[foo bar]
      Legion::Settings[:llm][:rag][:trivial_max_chars] = 10

      request = Legion::LLM::Pipeline::Request.build(messages: [{ role: :user, content: 'foo' }])
      step = klass.new(request)
      expect(step.send(:trivial_query?, 'foo')).to be true
      expect(step.send(:trivial_query?, 'hello')).to be false
    end
  end

  describe '#step_rag_context' do
    it 'skips when strategy is :none via explicit override' do
      request = Legion::LLM::Pipeline::Request.build(
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

      request = Legion::LLM::Pipeline::Request.build(
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

      request = Legion::LLM::Pipeline::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      step.step_rag_context
      expect(step.enrichments).to have_key('rag:context_retrieval')
    end

    it 'skips when rag is disabled in settings' do
      Legion::Settings[:llm][:rag][:enabled] = false

      request = Legion::LLM::Pipeline::Request.build(
        messages:         [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      step.step_rag_context
      expect(step.enrichments).not_to have_key('rag:context_retrieval')
    end

    it 'populates enrichments when Apollo returns results' do
      request = Legion::LLM::Pipeline::Request.build(
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

      request = Legion::LLM::Pipeline::Request.build(
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

    it 'uses compact_limit for rag_compact strategy' do
      Legion::Settings[:llm][:rag][:compact_limit] = 3

      request = Legion::LLM::Pipeline::Request.build(
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
      request = Legion::LLM::Pipeline::Request.build(
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
      request = Legion::LLM::Pipeline::Request.build(
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
end
