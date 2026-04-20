# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Pipeline::Steps::Classification do
  let(:klass) do
    Class.new do
      include Legion::LLM::Pipeline::Steps::Classification

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

  def build_step(classification: nil, messages: [{ role: :user, content: 'hello world' }])
    request = Legion::LLM::Pipeline::Request.build(
      messages:       messages,
      classification: classification
    )
    klass.new(request)
  end

  describe '#step_classification' do
    context 'when classification is nil' do
      it 'runs scan with :public baseline and writes audit entry' do
        step = build_step(classification: nil)
        step.step_classification
        expect(step.audit).to have_key(:'classification:scan')
        expect(step.audit[:'classification:scan'][:outcome]).to eq(:success)
      end

      it 'runs scan with :public baseline and writes enrichments' do
        step = build_step(classification: nil)
        step.step_classification
        expect(step.enrichments).to have_key('classification:scan')
        expect(step.enrichments['classification:scan'][:declared_level]).to eq(:public)
      end
    end

    context 'when compliance.default_level is configured' do
      before do
        allow(Legion::Settings).to receive(:dig).and_call_original
        allow(Legion::Settings).to receive(:dig).with(:compliance, :default_level).and_return('internal')
        allow(Legion::Settings).to receive(:dig).with(:compliance, :classification_level).and_return(nil)
        allow(Legion::Settings).to receive(:dig).with(:compliance, :classification_scan).and_return(nil)
      end

      it 'uses configured default level as baseline' do
        step = build_step(classification: nil)
        step.step_classification
        expect(step.enrichments['classification:scan'][:declared_level]).to eq(:internal)
      end
    end

    context 'when compliance.classification_scan is false' do
      before do
        allow(Legion::Settings).to receive(:dig).and_call_original
        allow(Legion::Settings).to receive(:dig).with(:compliance, :classification_scan).and_return(false)
      end

      it 'skips the step entirely' do
        step = build_step(classification: nil)
        step.step_classification
        expect(step.audit).not_to have_key(:'classification:scan')
        expect(step.enrichments).not_to have_key('classification:scan')
      end
    end

    context 'when PHI is detected in an unclassified request' do
      it 'upgrades from :public baseline to :restricted' do
        step = build_step(
          classification: nil,
          messages:       [{ role: :user, content: 'patient medication list: lisinopril' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:declared_level]).to eq(:public)
        expect(step.enrichments['classification:scan'][:effective_level]).to eq(:restricted)
        expect(step.enrichments['classification:scan'][:upgraded]).to be true
      end
    end

    context 'when classification is provided' do
      it 'writes audit entry with success outcome' do
        step = build_step(classification: { level: :internal })
        step.step_classification
        expect(step.audit).to have_key(:'classification:scan')
        expect(step.audit[:'classification:scan'][:outcome]).to eq(:success)
      end

      it 'stores effective classification in enrichments' do
        step = build_step(classification: { level: :internal })
        step.step_classification
        expect(step.enrichments).to have_key('classification:scan')
        expect(step.enrichments['classification:scan'][:declared_level]).to eq(:internal)
      end

      it 'records timeline event' do
        step = build_step(classification: { level: :internal })
        step.step_classification
        keys = step.timeline.events.map { |e| e[:key] }
        expect(keys).to include('classification:scan')
      end
    end

    context 'PII detection' do
      it 'detects SSN pattern' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'my SSN is 123-45-6789' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_pii]).to be true
        expect(step.enrichments['classification:scan'][:detected_patterns]).to include(:ssn)
      end

      it 'detects email pattern' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'contact john.doe@example.com for help' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_pii]).to be true
        expect(step.enrichments['classification:scan'][:detected_patterns]).to include(:email)
      end

      it 'detects phone pattern' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'call me at 612-555-1234' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_pii]).to be true
        expect(step.enrichments['classification:scan'][:detected_patterns]).to include(:phone)
      end

      it 'detects IP address pattern' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'server at 192.168.1.100 is down' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_pii]).to be true
        expect(step.enrichments['classification:scan'][:detected_patterns]).to include(:ip_address)
      end

      it 'detects date of birth pattern' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'DOB: 01/15/1985' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_pii]).to be true
        expect(step.enrichments['classification:scan'][:detected_patterns]).to include(:date_of_birth)
      end

      it 'detects URL pattern' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'visit https://patient-portal.example.com/records' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_pii]).to be true
        expect(step.enrichments['classification:scan'][:detected_patterns]).to include(:url)
      end

      it 'detects MRN with number pattern' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'MRN: 12345678' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_pii]).to be true
        expect(step.enrichments['classification:scan'][:detected_patterns]).to include(:mrn)
      end

      it 'detects VIN pattern' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'vehicle 1HGBH41JXMN109186 was involved' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_pii]).to be true
        expect(step.enrichments['classification:scan'][:detected_patterns]).to include(:vin)
      end

      it 'sets contains_pii false when no PII found' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'what is 2 + 2?' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_pii]).to be false
      end
    end

    context 'PHI detection' do
      it 'detects PHI keyword' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'patient diagnosis is hypertension' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_phi]).to be true
        expect(step.enrichments['classification:scan'][:detected_patterns]).to include(:phi_keyword)
      end

      it 'detects expanded PHI keywords' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'health-plan beneficiary admission records' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_phi]).to be true
      end

      it 'sets contains_phi false when no PHI found' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'the quick brown fox' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_phi]).to be false
      end
    end

    context 'level upgrade' do
      it 'upgrades :internal to :restricted when PHI detected' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'patient medication list: lisinopril' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:effective_level]).to eq(:restricted)
        expect(step.enrichments['classification:scan'][:upgraded]).to be true
      end

      it 'does not downgrade :restricted when no sensitive data found' do
        step = build_step(
          classification: { level: :restricted },
          messages:       [{ role: :user, content: 'hello world' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:effective_level]).to eq(:restricted)
        expect(step.enrichments['classification:scan'][:upgraded]).to be false
      end

      it 'adds warning when classification is upgraded' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'patient SSN is 123-45-6789' }]
        )
        step.step_classification
        expect(step.warnings).not_to be_empty
        expect(step.warnings.first).to match(/upgraded/)
      end

      it 'does not add warning when no upgrade occurs' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'what is 2 + 2?' }]
        )
        step.step_classification
        expect(step.warnings).to be_empty
      end
    end
  end
end
