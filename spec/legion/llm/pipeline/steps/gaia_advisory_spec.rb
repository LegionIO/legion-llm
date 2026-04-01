# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::GaiaAdvisory do
  let(:klass) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::GaiaAdvisory

      attr_accessor :request, :enrichments, :timeline, :warnings

      def initialize(request)
        @request = request
        @enrichments = {}
        @timeline = Legion::LLM::Pipeline::Timeline.new
        @warnings = []
      end
    end
  end

  let(:request) do
    Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'list files' }],
      caller:   { requested_by: { identity: 'user:matt', type: :user } }
    )
  end

  describe '#step_gaia_advisory' do
    it 'populates enrichments when GAIA returns advisory' do
      gaia_mod = Module.new
      allow(gaia_mod).to receive(:advise).and_return({
                                                       valence:   [0.7],
                                                       tool_hint: ['list_files'],
                                                       suppress:  [:billing]
                                                     })
      stub_const('Legion::Gaia', gaia_mod)
      allow(gaia_mod).to receive(:started?).and_return(true)

      step = klass.new(request)
      step.step_gaia_advisory

      expect(step.enrichments).to have_key('gaia:advisory')
      expect(step.enrichments['gaia:advisory'][:data][:tool_hint]).to eq(['list_files'])
      expect(step.enrichments['gaia:advisory'][:data][:valence]).to eq([0.7])
    end

    it 'skips silently when GAIA is unavailable' do
      stub_const('Legion::Gaia', Module.new)
      allow(Legion::Gaia).to receive(:started?).and_return(false)

      step = klass.new(request)
      step.step_gaia_advisory

      expect(step.enrichments).not_to have_key('gaia:advisory')
      expect(step.warnings).to include(match(/GAIA unavailable/))
    end

    it 'skips when GAIA is not defined' do
      hide_const('Legion::Gaia')

      step = klass.new(request)
      step.step_gaia_advisory

      expect(step.enrichments).not_to have_key('gaia:advisory')
    end

    it 'records timeline event' do
      gaia_mod = Module.new
      allow(gaia_mod).to receive(:advise).and_return({ valence: [0.5] })
      allow(gaia_mod).to receive(:started?).and_return(true)
      stub_const('Legion::Gaia', gaia_mod)

      step = klass.new(request)
      step.step_gaia_advisory

      keys = step.timeline.events.map { |e| e[:key] }
      expect(keys).to include('gaia:advisory')
    end
  end

  describe 'calibration weight integration' do
    let(:gaia_mod) do
      mod = Module.new
      allow(mod).to receive(:started?).and_return(true)
      allow(mod).to receive(:advise).and_return({ valence: [0.6] })
      mod
    end

    before { stub_const('Legion::Gaia', gaia_mod) }

    context 'when calibration weights exist in Apollo Local' do
      before do
        apollo_local = double('Apollo::Local', started?: true)
        allow(apollo_local).to receive(:query).and_return({
                                                            success: true,
                                                            results: [{
                                                              content: '{"weights":{"tone_adjustment":0.3,"verbosity_adjustment":0.8}}'
                                                            }]
                                                          })
        stub_const('Legion::Apollo::Local', apollo_local)
      end

      it 'includes calibration_weights in advisory enrichment' do
        step = klass.new(request)
        step.step_gaia_advisory

        advisory_data = step.enrichments['gaia:advisory'][:data]
        expect(advisory_data[:calibration_weights]).to eq(
          'tone_adjustment' => 0.3, 'verbosity_adjustment' => 0.8
        )
      end
    end

    context 'when Apollo Local unavailable' do
      before { hide_const('Legion::Apollo::Local') }

      it 'proceeds without calibration weights' do
        step = klass.new(request)
        expect { step.step_gaia_advisory }.not_to raise_error
        expect(step.enrichments).to have_key('gaia:advisory')
      end
    end

    context 'when Apollo Local not started' do
      before do
        stub_const('Legion::Apollo::Local', double('Apollo::Local', started?: false))
      end

      it 'proceeds without calibration weights' do
        step = klass.new(request)
        step.step_gaia_advisory

        advisory_data = step.enrichments['gaia:advisory'][:data]
        expect(advisory_data[:calibration_weights]).to be_nil
      end
    end
  end

  describe 'advisory meta recording' do
    let(:gaia_mod) do
      mod = Module.new
      allow(mod).to receive(:started?).and_return(true)
      allow(mod).to receive(:advise).and_return({
                                                  valence:         [0.6],
                                                  partner_context: { standing: :good }
                                                })
      allow(mod).to receive(:record_advisory_meta)
      mod
    end

    before do
      stub_const('Legion::Gaia', gaia_mod)
      stub_const('Legion::Gaia::BondRegistry', double('BondRegistry', partner?: true))
      apollo_local = double('Apollo::Local', started?: true)
      allow(apollo_local).to receive(:query).and_return({ success: false, results: [] })
      stub_const('Legion::Apollo::Local', apollo_local)
    end

    it 'calls record_advisory_meta on partner interactions' do
      step = klass.new(request)
      step.step_gaia_advisory
      expect(gaia_mod).to have_received(:record_advisory_meta)
    end
  end
end
