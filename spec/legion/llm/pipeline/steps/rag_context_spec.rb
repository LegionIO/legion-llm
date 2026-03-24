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

  describe '#select_context_strategy' do
    it 'returns :full when utilization < 0.3' do
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.2)).to eq(:full)
    end

    it 'returns :recent + :rag hybrid when utilization 0.3-0.8' do
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.5)).to eq(:rag_hybrid)
    end

    it 'returns :rag when utilization > 0.8' do
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        context_strategy: :auto
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.9)).to eq(:rag)
    end

    it 'respects explicit strategy override' do
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        context_strategy: :none
      )
      step = klass.new(request)
      expect(step.send(:select_context_strategy, utilization: 0.5)).to eq(:none)
    end
  end

  describe '#step_rag_context' do
    it 'skips when strategy is :none' do
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        context_strategy: :none
      )
      step = klass.new(request)
      step.step_rag_context
      expect(step.enrichments).not_to have_key('rag:context_retrieval')
    end

    it 'populates enrichments when Apollo returns results' do
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'what is pgvector?' }],
        context_strategy: :rag
      )

      apollo_runner = double('Knowledge')
      allow(apollo_runner).to receive(:retrieve_relevant).and_return({
        success: true,
        entries: [
          { id: 'e1', content: 'pgvector is...', content_type: 'fact', confidence: 0.85 },
          { id: 'e2', content: 'cosine distance...', content_type: 'concept', confidence: 0.72 }
        ],
        count: 2
      })
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', apollo_runner)

      step = klass.new(request)
      step.step_rag_context
      expect(step.enrichments).to have_key('rag:context_retrieval')
      expect(step.enrichments['rag:context_retrieval'][:data][:entries].size).to eq(2)
    end

    it 'degrades gracefully when Apollo unavailable' do
      request = Legion::LLM::Pipeline::Request.build(
        messages: [{ role: :user, content: 'hello' }],
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
        messages: [{ role: :user, content: 'test' }],
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
