# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Steps::Classification do
  let(:klass) do
    Class.new do
      include Legion::LLM::Inference::Steps::Classification

      attr_accessor :request, :enrichments, :timeline, :warnings, :audit

      def initialize(request)
        @request     = request
        @enrichments = {}
        @timeline    = Legion::LLM::Inference::Timeline.new
        @warnings    = []
        @audit       = {}
      end
    end
  end

  def build_step(classification: nil, messages: [{ role: :user, content: 'hello world' }])
    request = Legion::LLM::Inference::Request.build(
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
        Legion::Settings[:llm][:compliance] = Legion::Settings[:llm][:compliance].merge(default_level: 'internal')
      end

      it 'uses configured default level as baseline' do
        step = build_step(classification: nil)
        step.step_classification
        expect(step.enrichments['classification:scan'][:declared_level]).to eq(:internal)
      end
    end

    context 'when compliance.classification_scan is false' do
      before do
        Legion::Settings[:llm][:compliance] = Legion::Settings[:llm][:compliance].merge(classification_scan: false)
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

    context 'PII detection (core patterns, strict_hipaa=false)' do
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

      it 'does not detect extended patterns when strict_hipaa is off' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'server at 192.168.1.100 is down' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_pii]).to be false
        expect(step.enrichments['classification:scan'][:detected_patterns]).not_to include(:ip_address)
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

    context 'PII detection (extended patterns, strict_hipaa=true)' do
      before do
        Legion::Settings[:llm][:compliance] = { strict_hipaa: true }
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

      it 'also detects core patterns when strict_hipaa is on' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'my SSN is 123-45-6789' }]
        )
        step.step_classification
        expect(step.enrichments['classification:scan'][:contains_pii]).to be true
        expect(step.enrichments['classification:scan'][:detected_patterns]).to include(:ssn)
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

    context 'redaction (redact_pii=false by default)' do
      it 'does not modify message content when redaction is disabled' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'my SSN is 123-45-6789' }]
        )
        step.step_classification
        expect(step.request.messages.first[:content]).to eq('my SSN is 123-45-6789')
        expect(step.enrichments).not_to have_key('classification:redaction')
      end
    end

    context 'redaction (redact_pii=true)' do
      before do
        Legion::Settings[:llm][:compliance] = { redact_pii: true }
      end

      it 'replaces detected PII with [REDACTED] in message content' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'my SSN is 123-45-6789' }]
        )
        step.step_classification
        expect(step.request.messages.first[:content]).to eq('my SSN is [REDACTED]')
      end

      it 'replaces multiple PII patterns' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'SSN 123-45-6789 email john@test.com call 612-555-1234' }]
        )
        step.step_classification
        content = step.request.messages.first[:content]
        expect(content).not_to include('123-45-6789')
        expect(content).not_to include('john@test.com')
        expect(content).not_to include('612-555-1234')
      end

      it 'replaces PHI keywords when PHI is detected' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'patient diagnosis is hypertension' }]
        )
        step.step_classification
        content = step.request.messages.first[:content]
        expect(content).not_to match(/\bpatient\b/i)
        expect(content).not_to match(/\bdiagnosis\b/i)
      end

      it 'records redaction enrichment' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'my SSN is 123-45-6789' }]
        )
        step.step_classification
        expect(step.enrichments).to have_key('classification:redaction')
        redaction = step.enrichments['classification:redaction']
        expect(redaction[:redacted]).to be true
        expect(redaction[:placeholder]).to eq('[REDACTED]')
        expect(redaction[:patterns_redacted]).to include(:ssn)
        expect(redaction[:timestamp]).to be_a(Time)
      end

      it 'does not redact when no PII or PHI is found' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'what is 2 + 2?' }]
        )
        step.step_classification
        expect(step.request.messages.first[:content]).to eq('what is 2 + 2?')
        expect(step.enrichments).not_to have_key('classification:redaction')
      end

      it 'skips non-string content in messages' do
        step = build_step(
          classification: { level: :internal },
          messages:       [
            { role: :user, content: 'my SSN is 123-45-6789' },
            { role: :user, content: nil }
          ]
        )
        step.step_classification
        expect(step.request.messages.first[:content]).to eq('my SSN is [REDACTED]')
        expect(step.request.messages.last[:content]).to be_nil
      end
    end

    context 'redaction with custom placeholder' do
      before do
        Legion::Settings[:llm][:compliance] = { redact_pii: true, redaction_placeholder: '***' }
      end

      it 'uses the custom placeholder' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'my SSN is 123-45-6789' }]
        )
        step.step_classification
        expect(step.request.messages.first[:content]).to eq('my SSN is ***')
        expect(step.enrichments['classification:redaction'][:placeholder]).to eq('***')
      end
    end

    context 'redaction with strict_hipaa=true' do
      before do
        Legion::Settings[:llm][:compliance] = { redact_pii: true, strict_hipaa: true }
      end

      it 'redacts extended patterns when strict_hipaa is on' do
        step = build_step(
          classification: { level: :internal },
          messages:       [{ role: :user, content: 'server at 192.168.1.100 is down' }]
        )
        step.step_classification
        expect(step.request.messages.first[:content]).to eq('server at [REDACTED] is down')
      end
    end

    context 'PHI cloud provider gate' do
      def build_gate_step(provider: nil, messages: nil)
        msgs = messages || [{ role: :user, content: 'patient medication list: lisinopril' }]
        routing = { provider: provider, model: nil }
        request = Legion::LLM::Inference::Request.build(
          messages: msgs,
          routing:  routing
        )
        klass.new(request)
      end

      context 'when phi_block_cloud=false (default) with restricted + cloud provider' do
        before do
          Legion::Settings[:llm] = { default_provider: :anthropic }
        end

        it 'permits with a warning' do
          step = build_gate_step(provider: :anthropic)
          step.step_classification
          expect(step.enrichments['classification:scan'][:effective_level]).to eq(:restricted)
          expect(step.warnings).to include(
            a_string_matching(%r{Restricted/sensitive content routing to cloud provider anthropic})
          )
        end
      end

      context 'when phi_block_cloud=true with restricted + cloud provider' do
        before do
          Legion::Settings[:llm][:compliance] = { phi_block_cloud: true }
          Legion::Settings[:llm][:default_provider] = :anthropic
        end

        it 'raises PipelineError' do
          step = build_gate_step(provider: :anthropic)
          expect { step.step_classification }.to raise_error(
            Legion::LLM::InferenceError,
            %r{Restricted/sensitive content.*cannot be sent to cloud provider anthropic}
          )
        end
      end

      context 'when phi_block_cloud=true with restricted + local provider (ollama)' do
        before do
          Legion::Settings[:llm][:compliance] = { phi_block_cloud: true }
          Legion::Settings[:llm][:default_provider] = :ollama
        end

        it 'permits without warning' do
          step = build_gate_step(provider: :ollama)
          step.step_classification
          expect(step.enrichments['classification:scan'][:effective_level]).to eq(:restricted)
          expect(step.warnings).not_to include(
            a_string_matching(%r{Restricted/sensitive content routing to cloud provider})
          )
        end
      end

      context 'when phi_block_cloud=true with non-restricted level + cloud provider' do
        before do
          Legion::Settings[:llm][:compliance] = { phi_block_cloud: true }
          Legion::Settings[:llm][:default_provider] = :anthropic
        end

        it 'permits because gate only fires on restricted' do
          step = build_gate_step(
            provider: :anthropic,
            messages: [{ role: :user, content: 'what is 2 + 2?' }]
          )
          step.step_classification
          expect(step.enrichments['classification:scan'][:effective_level]).to eq(:public)
          expect(step.warnings).to be_empty
        end
      end

      context 'with custom cloud_providers list' do
        before do
          Legion::Settings[:llm][:compliance] = {
            phi_block_cloud: true,
            cloud_providers: %i[anthropic openai]
          }
          Legion::Settings[:llm][:default_provider] = :bedrock
        end

        it 'permits bedrock when it is not in the custom cloud list' do
          step = build_gate_step(provider: :bedrock)
          step.step_classification
          expect(step.enrichments['classification:scan'][:effective_level]).to eq(:restricted)
          expect(step.warnings).not_to include(
            a_string_matching(%r{Restricted/sensitive content routing to cloud provider})
          )
        end

        it 'blocks anthropic when it is in the custom cloud list' do
          step = build_gate_step(provider: :anthropic)
          expect { step.step_classification }.to raise_error(
            Legion::LLM::InferenceError,
            /cannot be sent to cloud provider anthropic/
          )
        end
      end

      context 'when provider comes from default_provider setting (no explicit routing)' do
        before do
          Legion::Settings[:llm][:compliance] = { phi_block_cloud: true }
          Legion::Settings[:llm][:default_provider] = :openai
        end

        it 'blocks based on default provider when no explicit provider in routing' do
          step = build_gate_step(provider: nil)
          expect { step.step_classification }.to raise_error(
            Legion::LLM::InferenceError,
            /cannot be sent to cloud provider openai/
          )
        end
      end
    end
  end
end
