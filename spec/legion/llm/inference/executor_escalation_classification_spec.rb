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
      tier:        :cloud,
      provider:    :bedrock,
      instance:    :primary,
      model:       'anthropic.claude-sonnet-4',
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
      expect(Legion::LLM::Router.health_tracker).to receive(:trip_circuit).with(
        hash_including(provider: :bedrock, instance: :primary)
      )
      expect(Legion::LLM::Router.health_tracker).not_to receive(:report)

      executor.send(:record_escalation_failure, err, resolution, Time.now,
                    outcome: :auth_error, operation: 'llm.pipeline.escalation_attempt.auth')
    end

    it 'denies the model and trips the instance circuit for typed auth failures' do
      err = Legion::LLM::AuthError.new('vllm:qwen3.6-27b - Unauthorized')

      expect(Legion::LLM::Router.health_tracker).to receive(:deny_model).with(
        hash_including(provider: :bedrock, instance: :primary, model: 'anthropic.claude-sonnet-4')
      )
      expect(Legion::LLM::Router.health_tracker).to receive(:trip_circuit).with(
        hash_including(provider: :bedrock, instance: :primary)
      )
      expect(Legion::LLM::Router.health_tracker).not_to receive(:report)

      executor.send(:record_escalation_failure, err, resolution, Time.now,
                    outcome: :auth_error, operation: 'llm.pipeline.escalation_attempt.auth')
    end

    it 'reports provider health with instance for transport errors' do
      err = Faraday::ConnectionFailed.new('connection refused')

      expect(Legion::LLM::Router.health_tracker).to receive(:report).with(
        hash_including(
          provider:    :bedrock,
          instance:    :primary,
          offering_id: 'bedrock-primary-sonnet',
          signal:      :error
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

  describe '#run_provider_call_with_escalation' do
    it 'notifies streaming provider switches with router resolutions after a failed first attempt' do
      first = Legion::LLM::Router::Resolution.new(
        tier: :direct, provider: :vllm, instance: :v100, model: 'qwen3.6-27b'
      )
      second = Legion::LLM::Router::Resolution.new(
        tier: :direct, provider: :vllm, instance: :h200, model: 'gemma-4-31b-it'
      )
      chain = Legion::LLM::Router::EscalationChain.new(resolutions: [first, second], max_attempts: 2)
      observer = instance_double('StreamObserver', provider_switched: nil)

      allow(executor).to receive(:build_default_escalation_chain).and_return(chain)
      allow(executor).to receive(:attempt_escalation).and_return(false, true)
      executor.instance_variable_set(:@stream_observer, observer)

      expect do
        executor.send(:run_provider_call_with_escalation, stream_block: proc {})
      end.not_to raise_error
      expect(observer).to have_received(:provider_switched).with(
        from: an_instance_of(Legion::LLM::Router::Resolution),
        to:   second
      )
    end

    it 'logs non-primary failover attempts as warnings with the previous failure reason' do
      first = Legion::LLM::Router::Resolution.new(
        tier: :frontier, provider: :openai, instance: :env, model: 'gpt-5.4-mini'
      )
      second = Legion::LLM::Router::Resolution.new(
        tier: :direct, provider: :vllm, instance: :h200, model: 'gemma-4-31b-it'
      )
      chain = Legion::LLM::Router::EscalationChain.new(resolutions: [first, second], max_attempts: 2)
      logger = instance_double(Logger, debug: nil, info: nil, warn: nil)

      allow(executor).to receive(:build_default_escalation_chain).and_return(chain)
      allow(executor).to receive(:log).and_return(logger)
      allow(executor).to receive(:attempt_escalation) do |resolution, *_args|
        if resolution.provider == :openai
          executor.instance_variable_set(:@last_escalation_error,
                                         Legion::LLM::ProviderDown.new('first provider failed'))
          false
        else
          true
        end
      end

      expect do
        executor.send(:run_provider_call_with_escalation)
      end.not_to raise_error

      expect(logger).to have_received(:info).with(include('action=attempt', 'move=primary', 'provider=openai'))
      expect(logger).to have_received(:warn).with(
        include('action=attempt', 'move=escalation', 'provider=vllm', 'previous_error=Legion::LLM::ProviderDown')
      )
    end

    it 'treats provider-wrapped context overflow as a larger-window escalation signal' do
      first = Legion::LLM::Router::Resolution.new(
        tier: :fleet, provider: :vllm, instance: :h200, model: 'gemma-4-31b-it'
      )
      same_tier_other = Legion::LLM::Router::Resolution.new(
        tier: :fleet, provider: :vllm, instance: :h100, model: 'qwen3.6-27b'
      )
      larger_window = Legion::LLM::Router::Resolution.new(
        tier: :frontier, provider: :bedrock, instance: :claude, model: 'claude-1m'
      )
      chain = Legion::LLM::Router::EscalationChain.new(
        resolutions:  [first, same_tier_other, larger_window],
        max_attempts: 3
      )
      context_error = Legion::LLM::ProviderDown.new(
        "vllm:gemma-4-31b-it — This model's maximum context length is 262144 tokens. " \
        'However, your prompt contains at least 262145 input tokens.'
      )
      attempted = []

      allow(executor).to receive(:build_default_escalation_chain).and_return(chain)
      allow(executor).to receive(:attempt_escalation) do |resolution, *_args|
        attempted << resolution.model
        raise context_error if resolution == first

        resolution == larger_window
      end

      expect do
        executor.send(:run_provider_call_with_escalation)
      end.not_to raise_error

      expect(executor.instance_variable_get(:@resolved_provider)).to eq(:bedrock)
      expect(executor.instance_variable_get(:@resolved_model)).to eq('claude-1m')
      expect(attempted).not_to include('qwen3.6-27b')
    end
  end

  describe '#report_provider_failure' do
    it 'denies the model and trips the instance circuit for direct auth failures' do
      err = Legion::LLM::AuthError.new('vllm:qwen3.6-27b - Unauthorized')
      executor.instance_variable_set(:@resolved_provider, :vllm)
      executor.instance_variable_set(:@resolved_instance, :v100)
      executor.instance_variable_set(:@resolved_model, 'qwen3.6-27b')

      expect(Legion::LLM::Router.health_tracker).to receive(:deny_model).with(
        hash_including(provider: :vllm, instance: :v100, model: 'qwen3.6-27b')
      )
      expect(Legion::LLM::Router.health_tracker).to receive(:trip_circuit).with(
        hash_including(provider: :vllm, instance: :v100)
      )
      expect(Legion::LLM::Router.health_tracker).not_to receive(:report)

      executor.send(:report_provider_failure, err, status: 'auth_failed')
    end
  end
end
