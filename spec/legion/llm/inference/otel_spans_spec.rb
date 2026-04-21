# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline OTEL child spans' do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :test, model: 'test-model' }
    )
  end

  let(:executor) { Legion::LLM::Inference::Executor.new(request) }

  before do
    allow(executor).to receive(:step_provider_call).and_return(nil)
    allow(executor).to receive(:step_response_normalization).and_return(nil)
    executor.instance_variable_set(:@raw_response, double('response', content: 'ok', respond_to?: true))
  end

  describe '#telemetry_enabled?' do
    it 'returns false when Legion::Telemetry is not defined' do
      hide_const('Legion::Telemetry') if defined?(Legion::Telemetry)
      expect(executor.send(:telemetry_enabled?)).to be(false)
    end

    it 'returns false when Legion::Telemetry does not respond to enabled?' do
      stub_const('Legion::Telemetry', Module.new)
      expect(executor.send(:telemetry_enabled?)).to be(false)
    end

    it 'returns false when Legion::Telemetry.enabled? is false' do
      telemetry = Module.new do
        def self.enabled?
          false
        end
      end
      stub_const('Legion::Telemetry', telemetry)
      expect(executor.send(:telemetry_enabled?)).to be(false)
    end

    it 'returns true when Legion::Telemetry is available and enabled' do
      telemetry = Module.new do
        def self.enabled?
          true
        end
      end
      stub_const('Legion::Telemetry', telemetry)
      expect(executor.send(:telemetry_enabled?)).to be(true)
    end
  end

  describe '#pipeline_spans_enabled?' do
    it 'returns false when telemetry is not available' do
      allow(executor).to receive(:telemetry_enabled?).and_return(false)
      expect(executor.send(:pipeline_spans_enabled?)).to be(false)
    end

    it 'returns true when telemetry is enabled and pipeline_spans is true' do
      allow(executor).to receive(:telemetry_enabled?).and_return(true)
      Legion::Settings[:llm][:telemetry] = { pipeline_spans: true }
      expect(executor.send(:pipeline_spans_enabled?)).to be(true)
    end

    it 'returns false when telemetry enabled but pipeline_spans is false' do
      allow(executor).to receive(:telemetry_enabled?).and_return(true)
      Legion::Settings[:llm][:telemetry] = { pipeline_spans: false }
      expect(executor.send(:pipeline_spans_enabled?)).to be(false)
    end

    it 'defaults to true when telemetry_spans key is absent' do
      allow(executor).to receive(:telemetry_enabled?).and_return(true)
      Legion::Settings[:llm][:telemetry] = {}
      expect(executor.send(:pipeline_spans_enabled?)).to be(true)
    end
  end

  describe '#execute_step' do
    context 'when pipeline_spans is disabled' do
      before { allow(executor).to receive(:pipeline_spans_enabled?).and_return(false) }

      it 'yields the block directly without wrapping' do
        called = false
        executor.send(:execute_step, :rbac) { called = true }
        expect(called).to be(true)
      end

      it 'returns the block return value' do
        result = executor.send(:execute_step, :rbac) { 42 }
        expect(result).to eq(42)
      end
    end

    context 'when telemetry is enabled' do
      let(:fake_span) { double('span', set_attribute: nil) }
      let(:telemetry) do
        fs = fake_span
        mod = Module.new do
          define_singleton_method(:enabled?) { true }
          define_singleton_method(:with_span) do |_name, **_opts, &blk|
            blk.call(fs)
          end
        end
        mod
      end

      before do
        stub_const('Legion::Telemetry', telemetry)
        allow(executor).to receive(:pipeline_spans_enabled?).and_return(true)
      end

      it 'yields the block inside a span' do
        called = false
        executor.send(:execute_step, :rbac) { called = true }
        expect(called).to be(true)
      end

      it 'passes the correct span name' do
        received_name = nil
        allow(Legion::Telemetry).to receive(:with_span) do |name, **_opts, &blk|
          received_name = name
          blk.call(fake_span)
        end
        executor.send(:execute_step, :routing) { nil }
        expect(received_name).to eq('pipeline.routing')
      end

      it 'calls annotate_span with the span and step name' do
        expect(executor).to receive(:annotate_span).with(fake_span, :rbac)
        executor.send(:execute_step, :rbac) { nil }
      end

      it 'returns the block return value even when span is active' do
        result = executor.send(:execute_step, :rbac) { 'span_result' }
        expect(result).to eq('span_result')
      end
    end

    context 'when telemetry raises an error' do
      before do
        broken_telemetry = Module.new do
          def self.enabled?
            true
          end

          def self.with_span(_name, **_opts)
            raise 'telemetry broken'
          end
        end
        stub_const('Legion::Telemetry', broken_telemetry)
        allow(executor).to receive(:pipeline_spans_enabled?).and_return(true)
      end

      it 'still executes the step block' do
        called = false
        executor.send(:execute_step, :rbac) { called = true }
        expect(called).to be(true)
      end

      it 'returns the block return value from the rescue fallback' do
        result = executor.send(:execute_step, :rbac) { 'fallback' }
        expect(result).to eq('fallback')
      end
    end
  end

  describe '#annotate_span' do
    it 'sets attributes on the span from SpanAnnotator' do
      span = double('span', set_attribute: nil)
      audit = { 'rbac:permission_check': { outcome: :success, duration_ms: 3 } }
      executor.instance_variable_set(:@audit, audit)
      executor.instance_variable_set(:@enrichments, {})

      allow(Legion::LLM::Inference::Steps::SpanAnnotator).to receive(:attributes_for)
        .with(:rbac, audit: audit, enrichments: {})
        .and_return({ 'rbac.outcome' => 'success', 'rbac.duration_ms' => 3 })

      expect(span).to receive(:set_attribute).with('rbac.outcome', 'success')
      expect(span).to receive(:set_attribute).with('rbac.duration_ms', 3)
      executor.send(:annotate_span, span, :rbac)
    end

    it 'skips nil attribute values' do
      span = double('span')
      allow(Legion::LLM::Inference::Steps::SpanAnnotator).to receive(:attributes_for)
        .and_return({ 'foo' => nil, 'bar' => 'present' })

      expect(span).not_to receive(:set_attribute).with('foo', anything)
      expect(span).to receive(:set_attribute).with('bar', 'present')
      executor.send(:annotate_span, span, :routing)
    end

    it 'does nothing when span does not respond to set_attribute' do
      expect { executor.send(:annotate_span, Object.new, :rbac) }.not_to raise_error
    end

    it 'does not raise when SpanAnnotator raises' do
      span = double('span', set_attribute: nil)
      allow(Legion::LLM::Inference::Steps::SpanAnnotator).to receive(:attributes_for)
        .and_raise('annotator error')
      expect { executor.send(:annotate_span, span, :rbac) }.not_to raise_error
    end
  end

  describe '#annotate_top_level_span' do
    context 'when telemetry is not enabled' do
      before { allow(executor).to receive(:telemetry_enabled?).and_return(false) }

      it 'does nothing' do
        expect { executor.send(:annotate_top_level_span, steps_executed: 10, steps_skipped: 3) }.not_to raise_error
      end
    end

    context 'when telemetry is enabled' do
      let(:top_span) { double('top_span', set_attribute: nil) }

      before do
        allow(executor).to receive(:telemetry_enabled?).and_return(true)
        telemetry = Module.new do
          def self.enabled? = true
        end
        stub_const('Legion::Telemetry', telemetry)
        allow(Legion::Telemetry).to receive(:respond_to?).with(:current_span).and_return(true)
        allow(Legion::Telemetry).to receive(:current_span).and_return(top_span)
      end

      it 'sets steps_executed and steps_skipped on the top-level span' do
        expect(top_span).to receive(:set_attribute).with('legion.pipeline.steps_executed', 15)
        expect(top_span).to receive(:set_attribute).with('legion.pipeline.steps_skipped', 3)
        executor.send(:annotate_top_level_span, steps_executed: 15, steps_skipped: 3)
      end

      it 'sets cost_usd from billing audit when present' do
        executor.instance_variable_set(:@audit, { 'billing:budget_check': { estimated_cost_usd: 0.005 } })
        allow(top_span).to receive(:set_attribute)
        executor.send(:annotate_top_level_span, steps_executed: 10, steps_skipped: 0)
      end

      it 'does not raise when current_span is nil' do
        allow(Legion::Telemetry).to receive(:current_span).and_return(nil)
        expect { executor.send(:annotate_top_level_span, steps_executed: 10, steps_skipped: 0) }.not_to raise_error
      end

      it 'does not raise on internal errors' do
        allow(Legion::Telemetry).to receive(:current_span).and_raise('oops')
        expect { executor.send(:annotate_top_level_span, steps_executed: 10, steps_skipped: 0) }.not_to raise_error
      end
    end
  end

  describe 'pipeline execution with spans disabled' do
    before do
      Legion::Settings[:llm][:telemetry] = { pipeline_spans: false }
      allow(executor).to receive(:step_provider_call) do
        executor.instance_variable_set(:@raw_response, double('resp', content: 'ok'))
      end
      allow(executor).to receive(:step_response_normalization)
    end

    it 'executes all steps without wrapping and returns a Response' do
      response = executor.call
      expect(response).to be_a(Legion::LLM::Inference::Response)
    end
  end

  describe 'pipeline execution with spans enabled but Legion::Telemetry absent' do
    before do
      hide_const('Legion::Telemetry') if defined?(Legion::Telemetry)
      Legion::Settings[:llm][:telemetry] = { pipeline_spans: true }
      allow(executor).to receive(:step_provider_call) do
        executor.instance_variable_set(:@raw_response, double('resp', content: 'ok'))
      end
      allow(executor).to receive(:step_response_normalization)
    end

    it 'executes all steps normally without OTEL and returns a Response' do
      response = executor.call
      expect(response).to be_a(Legion::LLM::Inference::Response)
    end
  end
end
