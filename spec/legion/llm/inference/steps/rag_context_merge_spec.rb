# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::RagContext, 'merged retrieval results' do
  let(:strategy) { :rag }
  let(:query) { 'Explain the deployment decisions from the earlier conversation.' }
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: query }], context_strategy: strategy,
      conversation_id: 'rag-merge-conversation'
    )
  end
  let(:executor) { Legion::LLM::Inference::Executor.new(request) }
  let(:first) { { id: 'fact-1', content: 'Deploy the verified artifact.', content_type: 'fact' }.freeze }
  let(:second) { { id: 'fact-2', content: 'Retain the previous artifact.', content_type: 'fact' }.freeze }
  let(:third) { { id: 'fact-3', content: 'Check the deployment health.', content_type: 'fact' }.freeze }
  let(:general) { { success: true, entries: [first] } }
  let(:history) { { success: true, entries: [second, third] } }

  before do
    Legion::Settings[:llm][:rag][:full_limit] = 2
    Legion::Settings[:llm][:rag][:compact_limit] = 1
    Legion::Settings[:llm][:rag][:exclude_source_agents] = []
    allow(executor).to receive(:apollo_available?).and_return(true)
    # Substitute the two external retrievals, leaving merge, policy, accounting
    # and prompt assembly real.
    allow(executor).to receive(:apollo_retrieve_general).and_return(general)
    allow(executor).to receive(:apollo_retrieve_conversation_history).and_return(history)
  end

  def injected_entries
    executor.step_rag_context
    executor.enrichments.fetch('rag:context_retrieval').fetch(:data).fetch(:entries)
  end

  def retrieve
    executor.send(:apollo_retrieve, query: query, strategy: strategy)
  end

  it 'applies one full-strategy limit after merging, retaining retrieval order' do
    expect(injected_entries).to eq([first, second])
    expect(executor.enrichments['rag:context_retrieval'][:data][:count]).to eq(2)
    expect(executor.context_accounting[:counts][:rag_entry_count]).to eq(2)
    prompt = Legion::LLM::Inference::EnrichmentInjector.inject(system: nil, enrichments: executor.enrichments)
    expect(prompt).to include(first[:content], second[:content])
    expect(prompt).not_to include(third[:content])
  end

  context 'with duplicate content hashes across the two retrievals' do
    let(:first) { super().merge(content_hash: 'shared-content').freeze }
    let(:history) { { success: true, entries: [first.merge(id: 'different-id'), second] } }

    it 'injects the shared fact once and fills the budget with the next distinct fact' do
      expect(injected_entries).to eq([first, second])
      prompt = Legion::LLM::Inference::EnrichmentInjector.inject(system: nil, enrichments: executor.enrichments)
      expect(prompt.scan(first[:content]).size).to eq(1)
    end
  end

  context 'with the same source and ID and no content hash' do
    let(:first) { super().merge(source: :local).freeze }
    let(:history) { { success: true, entries: [first.merge(confidence: 0.9), second] } }

    it 'keeps the first retrieved record without changing its metadata' do
      expect(injected_entries).to eq([first, second])
      expect(first).not_to have_key(:confidence)
    end
  end

  context 'with equal IDs from different stores' do
    let(:general) { { success: true, entries: [first.merge(source: :local)] } }
    let(:history) { { success: true, entries: [second.merge(id: first[:id], source: :global)] } }

    it 'keeps both independently identified facts' do
      expect(injected_entries.map { |entry| entry[:content] }).to eq([first[:content], second[:content]])
    end
  end

  context 'without hashes or IDs' do
    let(:general) { [first.except(:id)] }
    let(:history) { { success: true, entries: [first.except(:id), second.except(:id)] } }

    it 'deduplicates equal content while preserving distinct anonymous facts' do
      expect(injected_entries).to eq([first.except(:id), second.except(:id)])
    end
  end

  context 'with a compact strategy' do
    let(:strategy) { :rag_compact }

    it 'uses the compact budget for the combined enrichment' do
      expect(injected_entries).to eq([first])
    end
  end

  it 'honors the smaller GAIA context limit across both retrievals' do
    executor.enrichments['gaia:advisory'] = { data: { context_window: { limit: 1 } } }
    expect(injected_entries).to eq([first])
  end

  context 'with an excluded source preceding an allowed duplicate' do
    let(:general) { { success: true, entries: [first.merge(content_hash: 'shared', source_agent: 'excluded')] } }
    let(:history) { { success: true, entries: [first.merge(content_hash: 'shared', source_agent: 'allowed'), second] } }

    it 'filters excluded sources before deduplication and the combined cap' do
      Legion::Settings[:llm][:rag][:exclude_source_agents] = ['excluded']
      expect(injected_entries).to eq(history[:entries])
    end

    context 'with string-keyed entry metadata' do
      let(:general) do
        { success: true, entries: [first.merge(content_hash: 'shared', source_agent: 'excluded').transform_keys(&:to_s)] }
      end

      it 'does not let the excluded copy hide the allowed fact' do
        Legion::Settings[:llm][:rag][:exclude_source_agents] = ['excluded']
        expect(injected_entries).to eq(history[:entries])
      end
    end
  end

  context 'with an empty-array fallback and a successful empty response' do
    let(:general) { [] }
    let(:history) { { success: true, entries: [] } }

    it 'preserves successful-empty retrieval without raising or adding context' do
      expect(retrieve).to include(success: true, entries: [], count: 0)
      executor.step_rag_context
      expect(executor.warnings).to be_empty
      expect(executor.enrichments).not_to have_key('rag:context_retrieval')
    end
  end

  [nil, [], { success: false, error: 'unavailable' }].each do |fallback|
    context "with #{fallback.inspect} and a failed retrieval" do
      let(:general) { fallback }
      let(:history) { { success: false, error: 'unavailable' } }

      it 'does not manufacture successful-empty status' do
        expect(retrieve).to include(success: false, entries: [], count: 0)
      end
    end
  end

  context 'with an array result and a failed response carrying stale entries' do
    let(:general) { [first] }
    let(:history) { { success: false, entries: [second], error: 'unavailable' } }

    it 'uses the successful facts without injecting the failed response entries' do
      expect(injected_entries).to eq([first])
      expect(retrieve).to include(success: true, count: 1)
    end
  end

  context 'when history retrieval is disabled and general retrieval fails' do
    let(:general) { { success: false, error: 'unavailable' } }

    it 'does not count the skipped history lookup as a successful retrieval' do
      Legion::Settings[:llm][:rag][:conversation_history_enabled] = false
      allow(executor).to receive(:apollo_retrieve_conversation_history).and_call_original
      expect(retrieve).to include(success: false, entries: [], count: 0)
    end
  end

  context 'when there is no conversation and general retrieval fails' do
    let(:general) { { success: false, error: 'unavailable' } }
    let(:request) { super().with(conversation_id: nil) }

    it 'does not count the missing history lookup as a successful retrieval' do
      Legion::Settings[:llm][:rag][:conversation_history_enabled] = true
      allow(executor).to receive(:apollo_retrieve_conversation_history).and_call_original
      expect(retrieve).to include(success: false, entries: [], count: 0)
    end
  end
end
