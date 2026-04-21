# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::Rbac do
  let(:klass) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::Rbac

      attr_accessor :request, :audit, :timeline, :warnings

      def initialize(request)
        @request  = request
        @audit    = {}
        @timeline = Legion::LLM::Pipeline::Timeline.new
        @warnings = []
      end
    end
  end

  let(:caller_hash) do
    {
      requested_by: {
        id:       'user:matt',
        identity: 'user:matt',
        type:     :human,
        roles:    ['llm_user'],
        team:     'platform'
      }
    }
  end

  let(:request) do
    Legion::LLM::Pipeline::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      caller:   caller_hash
    )
  end

  describe '#step_rbac' do
    context 'when legion-rbac is not available' do
      before { hide_const('Legion::Rbac') if defined?(Legion::Rbac) }

      it 'permits the request without raising' do
        step = klass.new(request)
        expect { step.step_rbac }.not_to raise_error
      end

      it 'adds a warning about rbac being unavailable with fail_open' do
        step = klass.new(request)
        step.step_rbac
        expect(step.warnings).to include(match(/rbac unavailable.*fail_open/i))
      end

      it 'records success outcome in audit' do
        step = klass.new(request)
        step.step_rbac
        expect(step.audit[:'rbac:permission_check'][:outcome]).to eq(:success)
      end

      it 'records timeline event' do
        step = klass.new(request)
        step.step_rbac
        keys = step.timeline.events.map { |e| e[:key] }
        expect(keys).to include('rbac:permission_check')
      end
    end

    context 'when legion-rbac is not available and fail_open=true (explicit)' do
      before do
        hide_const('Legion::Rbac') if defined?(Legion::Rbac)
        Legion::Settings[:rbac] = { fail_open: true }
      end

      it 'permits non-fleet callers with warning' do
        step = klass.new(request)
        expect { step.step_rbac }.not_to raise_error
        expect(step.warnings).to include(match(/fail_open/i))
      end
    end

    context 'when legion-rbac is not available and fail_open=false' do
      before do
        hide_const('Legion::Rbac') if defined?(Legion::Rbac)
        Legion::Settings[:rbac] = { fail_open: false }
      end

      it 'raises PipelineError for non-fleet callers' do
        step = klass.new(request)
        expect { step.step_rbac }.to raise_error(Legion::LLM::PipelineError, /503/)
      end

      it 'includes fail_open=false in error message' do
        step = klass.new(request)
        expect { step.step_rbac }.to raise_error(Legion::LLM::PipelineError, /fail_open=false/)
      end

      it 'records failure in audit' do
        step = klass.new(request)
        step.step_rbac rescue Legion::LLM::PipelineError # rubocop:disable Style/RescueModifier
        expect(step.audit[:'rbac:permission_check'][:outcome]).to eq(:failure)
      end
    end

    context 'when legion-rbac is not available and caller is fleet (regardless of fail_open)' do
      let(:fleet_request) do
        Legion::LLM::Pipeline::Request.build(
          messages: [{ role: :user, content: 'hello' }],
          caller:   {
            requested_by: { id: 'system', type: :system },
            agent:        { id: 'fleet:worker-1' }
          }
        )
      end

      before { hide_const('Legion::Rbac') if defined?(Legion::Rbac) }

      it 'raises PipelineError even when fail_open=true' do
        Legion::Settings[:rbac] = { fail_open: true }
        step = klass.new(fleet_request)
        expect { step.step_rbac }.to raise_error(Legion::LLM::PipelineError, /503/)
      end

      it 'raises PipelineError when fail_open=false' do
        Legion::Settings[:rbac] = { fail_open: false }
        step = klass.new(fleet_request)
        expect { step.step_rbac }.to raise_error(Legion::LLM::PipelineError, /503/)
      end

      it 'raises PipelineError when fail_open setting is not present' do
        step = klass.new(fleet_request)
        expect { step.step_rbac }.to raise_error(Legion::LLM::PipelineError, /503/)
      end
    end

    context 'when legion-rbac is available and permission is granted' do
      before do
        principal_class = Class.new do
          attr_reader :id, :type, :roles, :team

          def initialize(id:, type: :human, roles: [], team: nil, **)
            @id    = id
            @type  = type
            @roles = roles
            @team  = team
          end
        end

        rbac_mod = Module.new
        rbac_mod.const_set(:Principal, principal_class)
        allow(rbac_mod).to receive(:authorize!).and_return(
          { allowed: true, principal_id: 'user:matt', action: 'use', resource: 'llm/pipeline' }
        )
        stub_const('Legion::Rbac', rbac_mod)
      end

      it 'does not raise an error' do
        step = klass.new(request)
        expect { step.step_rbac }.not_to raise_error
      end

      it 'records success outcome in audit' do
        step = klass.new(request)
        step.step_rbac
        expect(step.audit[:'rbac:permission_check'][:outcome]).to eq(:success)
      end

      it 'records timeline event' do
        step = klass.new(request)
        step.step_rbac
        keys = step.timeline.events.map { |e| e[:key] }
        expect(keys).to include('rbac:permission_check')
      end

      it 'calls authorize! with llm/pipeline resource and :use action' do
        step = klass.new(request)
        step.step_rbac
        expect(Legion::Rbac).to have_received(:authorize!).with(
          hash_including(action: :use, resource: 'llm/pipeline')
        )
      end

      it 'does not add warnings' do
        step = klass.new(request)
        step.step_rbac
        expect(step.warnings).to be_empty
      end

      it 'includes duration_ms in audit entry' do
        step = klass.new(request)
        step.step_rbac
        expect(step.audit[:'rbac:permission_check']).to have_key(:duration_ms)
      end
    end

    context 'when legion-rbac is available and permission is denied' do
      before do
        access_denied_class = Class.new(StandardError)

        principal_class = Class.new do
          def initialize(**); end
        end

        rbac_mod = Module.new
        rbac_mod.const_set(:Principal, principal_class)
        rbac_mod.const_set(:AccessDenied, access_denied_class)
        allow(rbac_mod).to receive(:authorize!).and_raise(
          access_denied_class, 'no roles assigned (llm/pipeline / use)'
        )
        stub_const('Legion::Rbac', rbac_mod)
      end

      it 'raises PipelineError' do
        step = klass.new(request)
        expect { step.step_rbac }.to raise_error(Legion::LLM::PipelineError)
      end

      it 'includes 403 in the error message' do
        step = klass.new(request)
        expect { step.step_rbac }.to raise_error(Legion::LLM::PipelineError, /403/)
      end

      it 'records failure outcome in audit' do
        step = klass.new(request)
        step.step_rbac rescue Legion::LLM::PipelineError # rubocop:disable Style/RescueModifier
        expect(step.audit[:'rbac:permission_check'][:outcome]).to eq(:failure)
      end

      it 'records timeline event on denial' do
        step = klass.new(request)
        step.step_rbac rescue Legion::LLM::PipelineError # rubocop:disable Style/RescueModifier
        keys = step.timeline.events.map { |e| e[:key] }
        expect(keys).to include('rbac:permission_check')
      end
    end

    context 'with nil caller' do
      let(:request) do
        Legion::LLM::Pipeline::Request.build(
          messages: [{ role: :user, content: 'hello' }],
          caller:   nil
        )
      end

      before do
        principal_class = Class.new do
          attr_reader :id

          def initialize(id:, **)
            @id = id
          end
        end

        rbac_mod = Module.new
        rbac_mod.const_set(:Principal, principal_class)
        allow(rbac_mod).to receive(:authorize!).and_return({ allowed: true })
        stub_const('Legion::Rbac', rbac_mod)
      end

      it 'falls back to anonymous identity' do
        step = klass.new(request)
        step.step_rbac
        expect(Legion::Rbac).to have_received(:authorize!).with(
          hash_including(principal: have_attributes(id: 'anonymous'))
        )
      end
    end

    context 'profile skip behavior' do
      it 'is in the GAIA skip list' do
        expect(Legion::LLM::Pipeline::Profile::GAIA_SKIP).to include(:rbac)
      end

      it 'is in the SYSTEM skip list' do
        expect(Legion::LLM::Pipeline::Profile::SYSTEM_SKIP).to include(:rbac)
      end
    end
  end
end
