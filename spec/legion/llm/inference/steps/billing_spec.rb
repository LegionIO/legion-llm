# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::Billing do
  let(:klass) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::Billing

      attr_accessor :request, :enrichments, :timeline, :warnings, :audit

      def initialize(request)
        @request     = request
        @enrichments = {}
        @timeline    = Legion::LLM::Pipeline::Timeline.new
        @warnings    = []
        @audit       = {}
      end
    end
  end

  def build_step(billing: nil, messages: [{ role: :user, content: 'hello' }], model: nil)
    request = Legion::LLM::Pipeline::Request.build(
      messages: messages,
      billing:  billing,
      routing:  { provider: nil, model: model }
    )
    klass.new(request)
  end

  describe '#step_billing' do
    context 'when billing is nil' do
      it 'skips without writing to audit' do
        step = build_step(billing: nil)
        step.step_billing
        expect(step.audit).not_to have_key(:'billing:budget_check')
      end

      it 'skips without writing to enrichments' do
        step = build_step(billing: nil)
        step.step_billing
        expect(step.enrichments).not_to have_key('billing:budget_check')
      end
    end

    context 'when billing is provided without spending_cap' do
      it 'records budget_id in enrichments' do
        step = build_step(billing: { cost_center: 'eng', budget_id: 'bud_001' })
        step.step_billing
        expect(step.enrichments).to have_key('billing:budget_check')
        expect(step.enrichments['billing:budget_check'][:budget_id]).to eq('bud_001')
      end

      it 'records audit entry with success outcome' do
        step = build_step(billing: { cost_center: 'eng', budget_id: 'bud_001' })
        step.step_billing
        expect(step.audit[:'billing:budget_check'][:outcome]).to eq(:success)
      end

      it 'records timeline event' do
        step = build_step(billing: { cost_center: 'eng' })
        step.step_billing
        keys = step.timeline.events.map { |e| e[:key] }
        expect(keys).to include('billing:budget_check')
      end
    end

    context 'when spending_cap is set' do
      it 'allows the request when estimated cost is under cap' do
        step = build_step(
          billing:  { spending_cap: 1.0 },
          messages: [{ role: :user, content: 'hi' }]
        )
        expect { step.step_billing }.not_to raise_error
        expect(step.audit[:'billing:budget_check'][:outcome]).to eq(:success)
      end

      it 'raises PipelineError when estimated cost exceeds spending_cap' do
        step = build_step(
          billing:  { spending_cap: 0.0 },
          messages: [{ role: :user, content: 'a' * 100_000 }]
        )
        expect { step.step_billing }.to raise_error(Legion::LLM::PipelineError, /budget_exceeded/)
      end

      it 'includes estimated_cost_usd in enrichments' do
        step = build_step(
          billing:  { spending_cap: 1.0 },
          messages: [{ role: :user, content: 'hi' }]
        )
        step.step_billing
        expect(step.enrichments['billing:budget_check']).to have_key(:estimated_cost_usd)
      end
    end
  end
end
