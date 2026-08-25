# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/routing/outcome'

RSpec.describe Legion::LLM::Routing::Outcome do
  let(:classifier) { Class.new { include Legion::LLM::Routing::Outcome }.new }

  let(:selection) do
    instance_double('Selection', instance_key: 'vllm:h200', publisher_token_id: 'tok-abc-123')
  end

  let(:attempt_context) do
    instance_double('AttemptContext', selection: selection)
  end

  def outcome(kind, reason: kind.to_s, quota_domain: nil, retry_after: nil)
    instance_double('ProviderOutcome', kind: kind, reason: reason,
                                       quota_domain: quota_domain, retry_after: retry_after)
  end

  def classify(kind, attempts_remaining: 2, **rest)
    classifier.classify_outcome(
      outcome:            outcome(kind, **rest),
      attempt_context:    attempt_context,
      attempts_remaining: attempts_remaining
    )
  end

  describe '#classify_outcome' do
    it 'success -> Action.success with no transition or rejection' do
      action = classify(:success)
      expect(action).to be_success
      expect(action.global_transition).to be_nil
      expect(action.rejection).to be_nil
    end

    it 'instance_unavailable -> retry with a global transition (even at 0 remaining)' do
      action = classify(:instance_unavailable, attempts_remaining: 0)
      expect(action).to be_retry
      expect(action.global_transition).to be_a(Legion::LLM::Routing::Outcome::GlobalTransition)
      expect(action.global_transition.kind).to eq(:instance_unavailable)
      expect(action.global_transition.instance_key).to eq(attempt_context.selection.instance_key)
      expect(action.global_transition.publisher_token_id).to eq(attempt_context.selection.publisher_token_id)
    end

    %i[overloaded model_not_ready timeout connection_failure provider_error malformed_output
       tool_failure authentication authorization billing model_missing context_rejected].each do |kind|
      it "#{kind} -> retry with no global transition when attempts remain" do
        action = classify(kind, attempts_remaining: 1)
        expect(action).to be_retry
        expect(action.global_transition).to be_nil
        expect(action.exclusions).to eq([])
      end

      it "#{kind} -> terminal attempts_exhausted when no attempts remain" do
        action = classify(kind, attempts_remaining: 0)
        expect(action).to be_terminal
        expect(action.rejection.kind).to eq(:attempts_exhausted)
        expect(action.rejection.http_status).to eq(503)
      end
    end

    it 'rate_limited with authoritative quota_domain -> retry with quota-domain exclusion' do
      domain = instance_double('QuotaDomainKey')
      allow(domain).to receive(:is_a?).with(Legion::Extensions::Llm::Routing::QuotaDomainKey).and_return(true)

      action = classifier.classify_outcome(
        outcome:            outcome(:rate_limited, quota_domain: domain, retry_after: 30),
        attempt_context:    attempt_context,
        attempts_remaining: 2
      )
      expect(action).to be_retry
      expect(action.exclusions.map(&:target_kind)).to eq([:quota_domain])
      expect(action.exclusions.first.target).to eq(domain)
    end

    it 'rate_limited without quota_domain -> retry with no exclusions' do
      action = classify(:rate_limited, attempts_remaining: 2)
      expect(action).to be_retry
      expect(action.exclusions).to eq([])
    end

    %i[policy invalid_request safety_refusal].each do |kind|
      it "#{kind} -> terminal with no global transition" do
        action = classify(kind)
        expect(action).to be_terminal
        expect(action.global_transition).to be_nil
      end
    end

    it 'policy -> policy_denied 403' do
      action = classify(:policy)
      expect(action.rejection.kind).to eq(:policy_denied)
      expect(action.rejection.http_status).to eq(403)
    end

    it 'invalid_request -> invalid_request 400' do
      action = classify(:invalid_request)
      expect(action.rejection.kind).to eq(:invalid_request)
      expect(action.rejection.http_status).to eq(400)
    end

    it 'safety_refusal -> invalid_request 400' do
      action = classify(:safety_refusal)
      expect(action.rejection.kind).to eq(:invalid_request)
      expect(action.rejection.http_status).to eq(400)
    end

    %i[cancelled client_disconnect].each do |kind|
      it "#{kind} -> terminal preserving the outcome kind" do
        action = classify(kind)
        expect(action).to be_terminal
        expect(action.outcome.kind).to eq(kind)
      end
    end

    it 'raises ArgumentError for an unclassifiable kind' do
      expect { classify(:totally_unknown_kind) }.to raise_error(ArgumentError, /unclassifiable/)
    end
  end

  describe Legion::LLM::Routing::Outcome::Action do
    let(:outcome_double) { instance_double('ProviderOutcome', kind: :success) }
    let(:rejection_double) { instance_double('Rejection', kind: :attempts_exhausted) }

    describe 'disposition invariants' do
      it 'terminal requires a rejection' do
        expect do
          described_class.new(disposition: :terminal, outcome: outcome_double, rejection: nil)
        end.to raise_error(ArgumentError, /terminal requires a rejection/)
      end

      it 'success carries no rejection' do
        expect do
          described_class.new(disposition: :success, outcome: outcome_double, rejection: rejection_double)
        end.to raise_error(ArgumentError, /success carries no rejection/)
      end

      it 'success carries no global transition' do
        transition = Legion::LLM::Routing::Outcome::GlobalTransition.new(
          instance_key: 'k', publisher_token_id: 'p', reason: 'r'
        )
        expect do
          described_class.new(disposition: :success, outcome: outcome_double, global_transition: transition)
        end.to raise_error(ArgumentError, /success carries no rejection/)
      end

      it 'retry carries no rejection' do
        expect do
          described_class.new(disposition: :retry, outcome: outcome_double, rejection: rejection_double)
        end.to raise_error(ArgumentError, /retry carries no rejection/)
      end

      it 'raises for unknown disposition' do
        expect do
          described_class.new(disposition: :explode, outcome: outcome_double)
        end.to raise_error(ArgumentError, /unknown disposition/)
      end
    end

    describe 'predicate methods' do
      it '#success? is true only for success disposition' do
        action = described_class.success(outcome: outcome_double)
        expect(action.success?).to be true
        expect(action.retry?).to be false
        expect(action.terminal?).to be false
      end

      it '#retry? is true only for retry disposition' do
        action = described_class.retry(exclusions: [], outcome: outcome_double)
        expect(action.retry?).to be true
        expect(action.success?).to be false
        expect(action.terminal?).to be false
      end

      it '#terminal? is true only for terminal disposition' do
        action = described_class.terminal(rejection: rejection_double, outcome: outcome_double)
        expect(action.terminal?).to be true
        expect(action.success?).to be false
        expect(action.retry?).to be false
      end
    end
  end

  describe Legion::LLM::Routing::Outcome::GlobalTransition do
    it 'accepts :instance_unavailable as kind' do
      gt = described_class.new(instance_key: 'k', publisher_token_id: 'p', reason: 'down')
      expect(gt.kind).to eq(:instance_unavailable)
      expect(gt.instance_key).to eq('k')
      expect(gt.publisher_token_id).to eq('p')
      expect(gt.reason).to eq('down')
    end

    it 'rejects a non-:instance_unavailable kind' do
      expect do
        described_class.new(kind: :something_else, instance_key: 'k',
                            publisher_token_id: 'p', reason: 'r')
      end.to raise_error(ArgumentError, /unsupported global transition kind/)
    end

    it 'is frozen after construction' do
      gt = described_class.new(instance_key: 'k', publisher_token_id: 'p', reason: 'down')
      expect(gt).to be_frozen
    end
  end
end
