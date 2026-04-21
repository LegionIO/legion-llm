# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::Rbac do
  let(:klass) do
    Class.new do
      include Legion::LLM::Inference::Steps::Rbac

      attr_accessor :request, :audit, :timeline, :warnings

      def initialize(request)
        @request  = request
        @audit    = {}
        @timeline = Legion::LLM::Inference::Timeline.new
        @warnings = []
      end
    end
  end

  describe '#step_rbac fleet fail-closed' do
    context 'when RBAC is unavailable and caller is a fleet: agent' do
      before { hide_const('Legion::Rbac') if defined?(Legion::Rbac) }

      let(:fleet_request) do
        Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'run fleet task' }],
          caller:   {
            requested_by: { id: 'system', type: :system },
            agent:        { id: 'fleet:worker-7' }
          }
        )
      end

      it 'raises PipelineError (fail-closed)' do
        step = klass.new(fleet_request)
        expect { step.step_rbac }.to raise_error(Legion::LLM::InferenceError)
      end

      it 'includes "fleet" in the error message' do
        step = klass.new(fleet_request)
        expect { step.step_rbac }.to raise_error(Legion::LLM::InferenceError, /fleet/i)
      end

      it 'records failure in audit' do
        step = klass.new(fleet_request)
        step.step_rbac rescue Legion::LLM::InferenceError # rubocop:disable Style/RescueModifier
        expect(step.audit[:'rbac:permission_check'][:outcome]).to eq(:failure)
      end
    end

    context 'when RBAC is unavailable and caller is NOT a fleet: agent' do
      before { hide_const('Legion::Rbac') if defined?(Legion::Rbac) }

      let(:normal_request) do
        Legion::LLM::Inference::Request.build(
          messages: [{ role: :user, content: 'hello' }],
          caller:   {
            requested_by: { id: 'user:matt', type: :human }
          }
        )
      end

      it 'permits the request (permissive for non-fleet callers)' do
        step = klass.new(normal_request)
        expect { step.step_rbac }.not_to raise_error
      end
    end
  end
end
