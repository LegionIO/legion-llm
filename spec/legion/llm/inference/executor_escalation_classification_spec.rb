# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::LLM::Inference::Executor, 'escalation error classification' do
  let(:request) do
    Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'hello' }],
      routing:  { provider: :bedrock, model: 'anthropic.claude-sonnet-4' }
    )
  end
  let(:executor) { described_class.new(request) }
  let(:resolution) do
    Legion::LLM::Router::Resolution.new(
      tier: :cloud,
      provider: :bedrock,
      instance: :primary,
      model: 'anthropic.claude-sonnet-4',
      offering_id: 'bedrock-primary-sonnet'
    )
  end

  before do
    allow(Legion::LLM::Router).to receive(:routing_enabled?).and_return(true)
    allow(Legion::LLM::Audit).to receive(:emit_prompt)
    allow(executor).to receive(:emit_escalation_attempt_metering)
    allow(executor).to receive(:emit_escalation_attempt_audit)
  end

  describe '#record_escalation_failure' do
    it 'does not deny a model or report circuit error for request-payload validation errors' do
      err = Legion::LLM::ProviderError.new('ValidationException: tools.16.custom.input_schema.type: Field required')

      expect(Legion::LLM::Router.health_tracker).not_to receive(:deny_model)
      expect(Legion::LLM::Router.health_tracker).not_to receive(:report)

      executor.send(:record_escalation_failure, err, resolution, Time.now,
                    outcome: :error, operation: 'llm.pipeline.escalation_attempt')
    end

    it 'does not deny a model for messages validation errors' do
      err = Legion::LLM::ProviderError.new('ValidationException: messages.3.content: Field required')

      expect(Legion::LLM::Router.health_tracker).not_to receive(:deny_model)
      expect(Legion::LLM::Router.health_tracker).not_to receive(:report)

      executor.send(:record_escalation_failure, err, resolution, Time.now,
                    outcome: :error, operation: 'llm.pipeline.escalation_attempt')
    end

    it 'still denies the model for genuine provider/model configuration errors' do
      err = StandardError.new('AccessDeniedException: not authorized for model X')

      expect(Legion::LLM::Router.health_tracker).to receive(:deny_model).with(
        hash_including(provider: :bedrock, model: 'anthropic.claude-sonnet-4')
      )
      expect(Legion::LLM::Router.health_tracker).not_to receive(:report)

      executor.send(:record_escalation_failure, err, resolution, Time.now,
                    outcome: :auth_error, operation: 'llm.pipeline.escalation_attempt.auth')
    end

    it 'reports provider health with instance for transport errors' do
      err = Faraday::ConnectionFailed.new('connection refused')

      expect(Legion::LLM::Router.health_tracker).to receive(:report).with(
        hash_including(
          provider: :bedrock,
          instance: :primary,
          offering_id: 'bedrock-primary-sonnet',
          signal: :error
        )
      )

      executor.send(:record_escalation_failure, err, resolution, Time.now,
                    outcome: :error, operation: 'llm.pipeline.escalation_attempt')
    end

    it 'does not report health for context overflow errors' do
      err = Legion::LLM::ContextOverflow.new('context too long')

      expect(Legion::LLM::Router.health_tracker).not_to receive(:deny_model)
      expect(Legion::LLM::Router.health_tracker).not_to receive(:report)

      executor.send(:record_escalation_failure, err, resolution, Time.now,
                    outcome: :error, operation: 'llm.pipeline.escalation_attempt')
    end
  end
end
