# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::SpanAnnotator do
  describe '.attributes_for' do
    context 'rbac step' do
      it 'returns outcome and duration from audit' do
        audit = { 'rbac:permission_check': { outcome: :success, duration_ms: 5 } }
        attrs = described_class.attributes_for(:rbac, audit: audit, enrichments: {})
        expect(attrs['rbac.outcome']).to eq('success')
        expect(attrs['rbac.duration_ms']).to eq(5)
      end

      it 'returns empty hash when audit entry is missing' do
        expect(described_class.attributes_for(:rbac, audit: {}, enrichments: {})).to eq({})
      end
    end

    context 'classification step' do
      it 'returns pii and phi flags from enrichments' do
        enrichments = {
          'classification:scan' => { contains_pii: true, contains_phi: false }
        }
        attrs = described_class.attributes_for(:classification, audit: {}, enrichments: enrichments)
        expect(attrs['classification.pii_detected']).to be(true)
        expect(attrs['classification.phi_detected']).to be(false)
      end

      it 'returns empty hash when classification enrichment is absent' do
        expect(described_class.attributes_for(:classification, audit: {}, enrichments: {})).to eq({})
      end
    end

    context 'billing step' do
      it 'returns estimated cost from enrichments' do
        enrichments = {
          'billing:budget_check' => { estimated_cost_usd: 0.001234 }
        }
        attrs = described_class.attributes_for(:billing, audit: {}, enrichments: enrichments)
        expect(attrs['billing.estimated_cost_usd']).to eq(0.001234)
      end

      it 'returns empty hash when billing enrichment is absent' do
        expect(described_class.attributes_for(:billing, audit: {}, enrichments: {})).to eq({})
      end

      it 'omits nil cost gracefully' do
        enrichments = { 'billing:budget_check' => { estimated_cost_usd: nil } }
        attrs = described_class.attributes_for(:billing, audit: {}, enrichments: enrichments)
        expect(attrs).not_to have_key('billing.estimated_cost_usd')
      end
    end

    context 'rag_context step' do
      it 'returns entry count and strategy from enrichments' do
        enrichments = {
          'rag:context_retrieval' => { data: { count: 7, strategy: :rag } }
        }
        attrs = described_class.attributes_for(:rag_context, audit: {}, enrichments: enrichments)
        expect(attrs['rag.entry_count']).to eq(7)
        expect(attrs['rag.strategy']).to eq('rag')
      end

      it 'returns empty hash when rag enrichment is absent' do
        expect(described_class.attributes_for(:rag_context, audit: {}, enrichments: {})).to eq({})
      end
    end

    context 'routing step' do
      it 'returns strategy and tier from audit' do
        audit = {
          'routing:provider_selection': {
            outcome: :success,
            data:    { strategy: 'intent_match', tier: :cloud }
          }
        }
        attrs = described_class.attributes_for(:routing, audit: audit, enrichments: {})
        expect(attrs['routing.strategy']).to eq('intent_match')
        expect(attrs['routing.tier']).to eq('cloud')
      end

      it 'returns empty hash when routing audit is absent' do
        expect(described_class.attributes_for(:routing, audit: {}, enrichments: {})).to eq({})
      end
    end

    context 'provider_call step' do
      it 'returns token counts and duration from audit' do
        audit = {
          'provider:response': {
            duration_ms: 1200,
            data:        { input_tokens: 100, output_tokens: 250 }
          }
        }
        attrs = described_class.attributes_for(:provider_call, audit: audit, enrichments: {})
        expect(attrs['gen_ai.usage.input_tokens']).to eq(100)
        expect(attrs['gen_ai.usage.output_tokens']).to eq(250)
        expect(attrs['provider.duration_ms']).to eq(1200)
      end

      it 'returns empty hash when provider audit is absent' do
        expect(described_class.attributes_for(:provider_call, audit: {}, enrichments: {})).to eq({})
      end
    end

    context 'tool_calls step' do
      it 'returns empty hash (no dedicated audit key yet)' do
        expect(described_class.attributes_for(:tool_calls, audit: {}, enrichments: {})).to eq({})
      end
    end

    context 'confidence_scoring step' do
      it 'returns score and band from enrichments' do
        enrichments = {
          'confidence:score' => { score: 0.87, band: :high }
        }
        attrs = described_class.attributes_for(:confidence_scoring, audit: {}, enrichments: enrichments)
        expect(attrs['confidence.score']).to eq(0.87)
        expect(attrs['confidence.band']).to eq('high')
      end

      it 'returns empty hash when confidence enrichment is absent' do
        expect(described_class.attributes_for(:confidence_scoring, audit: {}, enrichments: {})).to eq({})
      end
    end

    context 'unknown step' do
      it 'returns an empty hash' do
        expect(described_class.attributes_for(:nonexistent_step, audit: {}, enrichments: {})).to eq({})
      end

      it 'handles string step name' do
        expect(described_class.attributes_for('nonexistent', audit: {}, enrichments: {})).to eq({})
      end
    end

    context 'nil / missing audit and enrichment data' do
      it 'handles nil audit gracefully' do
        expect(described_class.attributes_for(:rbac, audit: nil, enrichments: {})).to eq({})
      end

      it 'handles nil enrichments gracefully' do
        expect(described_class.attributes_for(:classification, audit: {}, enrichments: nil)).to eq({})
      end

      it 'handles completely empty inputs' do
        expect(described_class.attributes_for(:billing, audit: {}, enrichments: {})).to eq({})
      end
    end
  end
end
