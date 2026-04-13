# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::EnrichmentInjector do
  describe '.inject' do
    before do
      Legion::Settings[:llm][:system_baseline] = nil
    end

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

  describe 'system_baseline integration' do
    it 'prepends system_baseline from settings' do
      Legion::Settings[:llm][:system_baseline] = 'You are Legion.'

      result = described_class.inject(system: 'Be helpful.', enrichments: {})
      expect(result).to start_with('You are Legion.')
      expect(result).to include('Be helpful.')
    end

    it 'prepends baseline before GAIA and caller system' do
      Legion::Settings[:llm][:system_baseline] = 'Baseline prompt.'
      enrichments = {
        'gaia:system_prompt' => { content: 'GAIA advisory.' }
      }

      result = described_class.inject(system: 'Caller system.', enrichments: enrichments)

      baseline_pos = result.index('Baseline prompt.')
      gaia_pos     = result.index('GAIA advisory.')
      caller_pos   = result.index('Caller system.')

      expect(baseline_pos).to be < gaia_pos
      expect(gaia_pos).to be < caller_pos
    end

    it 'injects baseline even when system is nil and no enrichments' do
      Legion::Settings[:llm][:system_baseline] = 'You are Legion.'

      result = described_class.inject(system: nil, enrichments: {})
      expect(result).to eq('You are Legion.')
    end

    it 'skips baseline when set to nil' do
      Legion::Settings[:llm][:system_baseline] = nil

      result = described_class.inject(system: 'Original', enrichments: {})
      expect(result).to eq('Original')
    end

    it 'skips baseline when set to empty string' do
      Legion::Settings[:llm][:system_baseline] = ''

      result = described_class.inject(system: 'Original', enrichments: {})
      expect(result).to eq('Original')
    end
  end
end
