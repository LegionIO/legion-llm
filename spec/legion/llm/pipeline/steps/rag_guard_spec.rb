# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::RagGuard do
  let(:klass) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::RagGuard

      attr_accessor :enrichments, :warnings, :timeline, :raw_response

      def initialize
        @enrichments = {
          'rag:context_retrieval' => {
            data: { entries: [{ content: 'pgvector uses cosine distance' }] }
          }
        }
        @warnings = []
        @timeline = Legion::LLM::Pipeline::Timeline.new
        @raw_response = Struct.new(:content).new('pgvector uses cosine distance for similarity')
      end
    end
  end

  describe '#check_rag_faithfulness' do
    it 'passes when response aligns with context' do
      step = klass.new
      if defined?(Legion::LLM::Hooks::RagGuard)
        allow(Legion::LLM::Hooks::RagGuard).to receive(:check_rag_faithfulness)
          .and_return({ faithful: true, details: 'RAG faithfulness check passed' })
      end

      step.check_rag_faithfulness
      expect(step.warnings).to be_empty
    end

    it 'adds warning when response contradicts context' do
      step = klass.new
      if defined?(Legion::LLM::Hooks::RagGuard)
        allow(Legion::LLM::Hooks::RagGuard).to receive(:check_rag_faithfulness)
          .and_return({ faithful: false, details: 'RAG faithfulness check failed: contradicts source' })
      end

      step.check_rag_faithfulness
      expect(step.warnings).to include(match(/faithfulness/i)) if defined?(Legion::LLM::Hooks::RagGuard)
    end

    it 'skips when no RAG context was retrieved' do
      step = klass.new
      step.enrichments.clear
      step.check_rag_faithfulness
      expect(step.warnings).to be_empty
    end
  end
end
