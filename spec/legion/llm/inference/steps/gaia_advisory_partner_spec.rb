# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::GaiaAdvisory do
  let(:klass) do
    Class.new do
      include Legion::LLM::Inference::Steps::GaiaAdvisory

      attr_accessor :request, :enrichments, :timeline, :warnings

      def initialize(request)
        @request     = request
        @enrichments = {}
        @timeline    = Legion::LLM::Inference::Timeline.new
        @warnings    = []
      end
    end
  end

  def build_step(identity: 'agent:alpha', extra_caller: {})
    request = Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      caller:   { requested_by: { identity: identity, type: :agent }.merge(extra_caller) }
    )
    klass.new(request)
  end

  def stub_gaia(advisory:)
    gaia_mod = Module.new
    allow(gaia_mod).to receive(:advise).and_return(advisory)
    allow(gaia_mod).to receive(:started?).and_return(true)
    stub_const('Legion::Gaia', gaia_mod)
    gaia_mod
  end

  describe 'partner context enrichment in #step_gaia_advisory' do
    context 'when caller is a known partner' do
      before do
        stub_gaia(advisory: { valence: [0.8] })

        bond_registry = Module.new
        allow(bond_registry).to receive(:partner?).with('agent:alpha').and_return(true)
        stub_const('Legion::Gaia::BondRegistry', bond_registry)
      end

      it 'adds partner_context to the advisory enrichment' do
        allow_any_instance_of(klass).to receive(:build_partner_context).and_return({
                                                                                     standing:            :good,
                                                                                     compatibility:       0.9,
                                                                                     recent_sentiment:    :positive,
                                                                                     interaction_pattern: :frequent
                                                                                   })
        step = build_step
        step.step_gaia_advisory

        advisory_data = step.enrichments.dig('gaia:advisory', :data)
        expect(advisory_data).to have_key(:partner_context)
        expect(advisory_data[:partner_context][:standing]).to eq(:good)
      end

      it 'does not add partner_context when build_partner_context returns nil' do
        allow_any_instance_of(klass).to receive(:build_partner_context).and_return(nil)
        step = build_step
        step.step_gaia_advisory

        advisory_data = step.enrichments.dig('gaia:advisory', :data)
        expect(advisory_data).not_to have_key(:partner_context)
      end
    end

    context 'when caller is not a partner' do
      before do
        stub_gaia(advisory: { valence: [0.5] })

        bond_registry = Module.new
        allow(bond_registry).to receive(:partner?).with('agent:alpha').and_return(false)
        stub_const('Legion::Gaia::BondRegistry', bond_registry)
      end

      it 'does not add partner_context to enrichments' do
        step = build_step
        step.step_gaia_advisory

        advisory_data = step.enrichments.dig('gaia:advisory', :data)
        expect(advisory_data).not_to have_key(:partner_context)
      end
    end

    context 'when BondRegistry is not defined' do
      before { stub_gaia(advisory: { valence: [0.5] }) }

      it 'does not add partner_context and does not raise' do
        hide_const('Legion::Gaia::BondRegistry') if defined?(Legion::Gaia::BondRegistry)
        step = build_step
        expect { step.step_gaia_advisory }.not_to raise_error
        advisory_data = step.enrichments.dig('gaia:advisory', :data)
        expect(advisory_data).not_to have_key(:partner_context)
      end
    end

    context 'when advisory returns nil' do
      before do
        stub_gaia(advisory: nil)
        bond_registry = Module.new
        allow(bond_registry).to receive(:partner?).and_return(true)
        stub_const('Legion::Gaia::BondRegistry', bond_registry)
      end

      it 'does not raise and produces no partner_context enrichment' do
        step = build_step
        expect { step.step_gaia_advisory }.not_to raise_error
        expect(step.enrichments).not_to have_key('gaia:advisory')
      end
    end
  end

  describe '#build_partner_context' do
    let(:instance) do
      request = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hello' }],
        caller:   { requested_by: { identity: 'agent:alpha', type: :agent } }
      )
      klass.new(request)
    end

    context 'when Apollo Local is available' do
      it 'returns a hash with the expected keys' do
        apollo_local = double('Apollo::Local', started?: true)
        allow(apollo_local).to receive(:query)
          .with(text: anything, tags: ['partner'], limit: anything)
          .and_return({ success: true, results: [] })
        stub_const('Legion::Apollo::Local', apollo_local)

        result = instance.build_partner_context('agent:alpha')
        expect(result).to be_a(Hash)
        expect(result).to have_key(:standing)
        expect(result).to have_key(:compatibility)
        expect(result).to have_key(:recent_sentiment)
        expect(result).to have_key(:interaction_pattern)
      end
    end

    context 'when Apollo Local is unavailable' do
      it 'returns a default hash without raising' do
        hide_const('Legion::Apollo::Local') if defined?(Legion::Apollo::Local)
        result = instance.build_partner_context('agent:alpha')
        expect(result).to be_a(Hash)
        expect(result).to have_key(:standing)
      end
    end

    context 'when Apollo Local raises an error' do
      it 'returns nil without propagating' do
        apollo_local = double('Apollo::Local', started?: true)
        allow(apollo_local).to receive(:query).and_raise(StandardError, 'boom')
        stub_const('Legion::Apollo::Local', apollo_local)

        result = instance.build_partner_context('agent:alpha')
        expect(result).to be_nil
      end
    end
  end
end
