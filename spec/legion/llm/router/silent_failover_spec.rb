# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/stream_assembler'

# G30 / N×N invariant 5 — P5 commit 3 implementation
RSpec.describe 'Mid-stream failover is silent (P5)' do
  let(:emitter) do
    Class.new do
      attr_reader :events, :trailers

      def initialize
        @events   = []
        @trailers = {}
      end

      def on_start(**) = @events << { type: :start }
      def on_text_open(**) = @events << { type: :text_open }
      def on_text_delta(**) = @events << { type: :text_delta }
      def on_text_close(**) = @events << { type: :text_close }
      def on_thinking_open(**) = @events << { type: :thinking_open }
      def on_thinking_delta(**) = @events << { type: :thinking_delta }
      def on_thinking_close(**) = @events << { type: :thinking_close }
      def on_tool_call_open(**) = @events << { type: :tool_call_open }
      def on_tool_call_delta(**) = @events << { type: :tool_call_delta }
      def on_tool_call_close(**) = @events << { type: :tool_call_close }
      def on_server_tool_result(**) = @events << { type: :server_tool_result }
      def on_keep_alive = @events << { type: :keep_alive }
      def on_message_delta(**) = @events << { type: :message_delta }
      def on_done(**) = @events << { type: :done }
      def on_error(**) = @events << { type: :error }

      def on_trailers(trailers:)
        @trailers.merge!(trailers)
        @events << { type: :trailers, trailers: trailers }
      end
    end.new
  end

  let(:lane_a) do
    {
      id:              'cloud:bedrock:primary:inference:claude-sonnet-4-6',
      tier:            :cloud,
      provider_family: :bedrock,
      instance_id:     :primary,
      type:            :inference,
      model:           'claude-sonnet-4-6'
    }
  end
  let(:lane_b) do
    {
      id:              'frontier:anthropic:default:inference:claude-sonnet-4-6',
      tier:            :frontier,
      provider_family: :anthropic,
      instance_id:     :default,
      type:            :inference,
      model:           'claude-sonnet-4-6'
    }
  end

  describe 'StreamAssembler construction' do
    it 'requires non-nil initial_lane — raises ArgumentError when nil' do
      expect do
        Legion::LLM::API::StreamAssembler.new(emitter: emitter, request_id: 'r1', model: 'test', initial_lane: nil)
      end.to raise_error(ArgumentError, /initial_lane/)
    end

    it 'accepts a valid lane Hash' do
      expect do
        Legion::LLM::API::StreamAssembler.new(emitter: emitter, request_id: 'r1', model: 'test', initial_lane: lane_a)
      end.not_to raise_error
    end
  end

  describe 'provider_failover_pending!' do
    let(:assembler) do
      Legion::LLM::API::StreamAssembler.new(emitter: emitter, request_id: 'r1', model: 'test', initial_lane: lane_a)
    end

    it 'does not emit a custom SSE event for provider switch (silent per N×N invariant 5)' do
      assembler.provider_failover_pending!(from: lane_a)
      event_types = emitter.events.map { |e| e[:type] }
      expect(event_types).not_to include(:'provider-switch')
      expect(event_types).not_to include(:failover)
      expect(event_types).not_to include(:provider_switch)
    end
  end

  describe 'malformed lane redaction' do
    let(:logger) { instance_double('Logger', debug: nil, info: nil, warn: nil) }
    let(:log_messages) { [] }

    before do
      allow(logger).to receive(:debug) { |message| log_messages << message }
      allow(logger).to receive(:info) { |message| log_messages << message }
      allow(logger).to receive(:warn) { |message| log_messages << message }
    end

    it 'redacts every historically accepted malformed public lane value without changing state' do
      assembler = Legion::LLM::API::StreamAssembler.new(
        emitter: emitter, request_id: 'r1', model: 'test', initial_lane: lane_a
      )
      allow(assembler).to receive(:log).and_return(logger)

      invalid_utf8 = "bad\xFF".dup.force_encoding(Encoding::UTF_8)
      malformed = [
        'lane:v1:secret', nil, {}, { tier: :direct },
        lane_a.merge(model: ''), lane_a.merge(model: "line\nbreak"),
        lane_a.merge(model: invalid_utf8), lane_a.merge(type: :unknown)
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
        [lane_a[:id], *malformed.flat_map { |lane| [:failover_marker, lane.is_a?(Hash) ? lane[:id] : lane.to_s] }]
      )
    end
  end

  describe 'finalize with failover' do
    it 'emits debug trailers when failover happened' do
      assembler = Legion::LLM::API::StreamAssembler.new(
        emitter: emitter, request_id: 'r1', model: 'test', initial_lane: lane_a
      )
      assembler.provider_failover_pending!(from: lane_a)
      assembler.begin_dispatch_on(lane: lane_b)

      final_response = double('response',
                              respond_to?: false,
                              text:        nil,
                              tool_calls:  nil,
                              usage:       nil,
                              thinking:    nil,
                              metadata:    {})
      allow(final_response).to receive(:respond_to?).and_return(false)

      assembler.finalize(final_response)

      expect(emitter.trailers).to include(
        'x-legion-failover-from',
        'x-legion-failover-to',
        'x-legion-failover-count'
      )
      expect(emitter.trailers['x-legion-failover-from']).to eq(lane_a[:id])
      expect(emitter.trailers['x-legion-failover-to']).to eq(lane_b[:id])
      expect(emitter.trailers['x-legion-failover-count']).to eq('1')
    end

    it 'does NOT emit trailers when no failover occurred' do
      assembler = Legion::LLM::API::StreamAssembler.new(
        emitter: emitter, request_id: 'r1', model: 'test', initial_lane: lane_a
      )
      final_response = double('response',
                              respond_to?: false,
                              text:        nil,
                              tool_calls:  nil,
                              usage:       nil,
                              thinking:    nil,
                              metadata:    {})
      allow(final_response).to receive(:respond_to?).and_return(false)

      assembler.finalize(final_response)
      expect(emitter.trailers).to be_empty
    end
  end
end
