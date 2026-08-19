# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router/candidate_evaluation'
require 'legion/llm/router/ranker'
require 'legion/llm/api/stream_assembler'

RSpec.describe 'SSOT v3 routing log lane identity', :ssot_v3 do
  let(:logger) { instance_double('Logger', debug: nil, info: nil, warn: nil) }
  let(:log_messages) { [] }

  before do
    allow(logger).to receive(:debug) { |message| log_messages << message }
    allow(logger).to receive(:info) { |message| log_messages << message }
    allow(logger).to receive(:warn) { |message| log_messages << message }
  end

  def ranker_requirements
    Struct.new(
      :tier_preference, :required_context_budget, :routing_affinities,
      :affinity_strength_bps, :routing_seed,
      keyword_init: true
    ).new(
      tier_preference: nil, required_context_budget: 0,
      routing_affinities: [], affinity_strength_bps: 10_000,
      routing_seed: '0' * 32
    )
  end

  def evaluation_for(snap)
    lane = snap.each_lane.first
    offering = snap.offering(offering_id: lane.offering_id)
    instance = snap.instance(instance_key: lane.instance_key)
    Legion::LLM::Router::CandidateEvaluation.new(
      offering: offering, lane: lane, instance: instance,
      operation_state: :supported, pin_state: :match, policy_state: :allowed,
      capability_state: :supported, context_state: :not_applicable,
      dimension_state: :not_applicable, availability_state: :available,
      exclusion_state: :clear, fleet_contract_state: :not_applicable,
      weight_state: :enabled, weight_inputs: lane.weight_inputs
    )
  end

  it 'uses the Inventory five-tuple for ranked and selected lines without opaque lane ids' do
    activate(
      provider_family: 'testprovider', instance_id: 'testinst',
      drafts: [offering_draft(model: 'test-model', tier: :direct, supported: %i[chat])]
    )
    snap = snapshot
    candidate = evaluation_for(snap)
    evaluation_set = Legion::LLM::Router::EvaluationSet.new(
      candidates: [candidate], publication_statuses: [], inventory_generation: snap.generation
    )
    allow_any_instance_of(Legion::LLM::Router::Ranker).to receive(:log).and_return(logger)

    Legion::LLM::Router::Ranker.call(
      evaluation_set:    evaluation_set,
      requirements:      ranker_requirements,
      settings_snapshot: Legion::LLM::Router::SettingsState.current
    )

    decision_lines = log_messages.grep(/action=(?:ranked|selected)/)
    expect(decision_lines.size).to eq(2)
    expect(decision_lines).to all(include('lane=direct:testprovider:testinst:inference:test-model'))
    expect(decision_lines.join).not_to include('lane:v1:')
  end

  it 'redacts every historically accepted malformed public lane value without changing state' do
    full_lane = {
      id: 'direct:testprovider:testinst:inference:test-model', tier: :direct,
      provider_family: :testprovider, instance_id: :testinst,
      type: :inference, model: 'test-model'
    }
    emitter = instance_double('Emitter')
    assembler = Legion::LLM::API::StreamAssembler.new(
      emitter: emitter, request_id: 'req-test', model: 'test-model', initial_lane: full_lane
    )
    allow(assembler).to receive(:log).and_return(logger)
    invalid_utf8 = "bad\xFF".dup.force_encoding(Encoding::UTF_8)
    malformed = [
      'lane:v1:secret', nil, {}, { tier: :direct },
      full_lane.merge(model: ''), full_lane.merge(model: "line\nbreak"),
      full_lane.merge(model: invalid_utf8), full_lane.merge(type: :unknown)
    ]

    expect do
      malformed.each do |lane|
        assembler.provider_failover_pending!(from: lane)
        assembler.begin_dispatch_on(lane: lane)
      end
    end.not_to raise_error

    lines = log_messages.join("\n")
    expect(lines.scan('lane_identity_missing=true').size).to eq(malformed.size * 2)
    expect(lines).not_to include('lane:v1:secret', "line\nbreak", 'bad')
    expect(assembler.instance_variable_get(:@failover_chain)).to eq(
      [full_lane[:id], *malformed.flat_map { |lane| [:failover_marker, lane.is_a?(Hash) ? lane[:id] : lane.to_s] }]
    )
  end
end
