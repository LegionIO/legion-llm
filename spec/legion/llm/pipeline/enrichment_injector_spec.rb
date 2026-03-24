# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::EnrichmentInjector do
  describe '.inject' do
    it 'prepends RAG context to system prompt' do
      enrichments = {
        'rag:context_retrieval' => {
          data: {
            entries: [
              { content: 'pgvector uses HNSW indexes', content_type: 'fact', confidence: 0.9 },
              { content: 'cosine distance formula', content_type: 'concept', confidence: 0.75 }
            ]
          }
        }
      }

      result = described_class.inject(
        system:      'You are helpful.',
        enrichments: enrichments
      )

      expect(result).to include('pgvector uses HNSW indexes')
      expect(result).to include('cosine distance formula')
      expect(result).to include('You are helpful.')
    end

    it 'prepends GAIA system prompt' do
      enrichments = {
        'gaia:system_prompt' => { content: 'User prefers concise answers.' }
      }

      result = described_class.inject(system: nil, enrichments: enrichments)
      expect(result).to include('User prefers concise answers.')
    end

    it 'returns original system when no enrichments' do
      result = described_class.inject(system: 'Original', enrichments: {})
      expect(result).to eq('Original')
    end

    it 'handles nil system prompt' do
      result = described_class.inject(system: nil, enrichments: {})
      expect(result).to be_nil
    end
  end
end
