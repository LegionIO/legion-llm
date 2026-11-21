# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/router'

RSpec.describe Legion::LLM::Router, :ssot_v3 do
  def publish_scope_lane(provider: :vllm, instance: 'primary', model: 'bounded-model', context: 128_000,
                         tier: :local, supported: %i[chat stream_chat], capabilities: { tools: :supported })
    activate(provider_family: provider.to_s, instance_id: instance, drafts: [
               offering_draft(model: model, tier: tier, supported: supported, context: context,
                              max_output: 16_384, capabilities: capabilities)
             ])
  end

  def scope_router(routing: {}, tools: nil, max: 128_000, operation: :chat)
    request = Legion::LLM::Inference::Request.build_for_test(
      routing_seed: 'ab' * 16, routing: routing, messages: [{ role: :user, content: 'Hello.' }],
      tokens: { max: max }, tools: tools
    )
    described_class.new(request: request, operation: operation, body_model: nil)
  end

  def expect_rejection(router, kind:, status:)
    result = router.next_lane
    expect(result).to be_a(Legion::Extensions::Llm::Routing::Rejection)
    expect(result.kind).to eq(kind)
    expect(result.http_status).to eq(status)
    result
  end

  def add_unrelated_inventory
    publish_scope_lane(provider: :ollama, instance: 'unknown', model: 'unrelated', context: nil)
    claim_only(provider_family: 'openai', instance_id: 'starting')
  end

  describe 'known context failures' do
    it 'keeps a pinned known context rejection terminal despite unrelated unknown and initializing providers' do
      publish_scope_lane
      add_unrelated_inventory
      router = scope_router(routing: { provider: :vllm, model: 'bounded-model' })

      result = expect_rejection(router, kind: :context_rejected, status: 400)

      expect(router.required_output_tokens).to eq(128_000)
      expect(router.context_budget).to eq(router.input_bound + 128_000)
      expect(result.candidate_counts).to include(pin_match: 1, pin_mismatch: 1, context_unknown: 1, publication_initializing: 1)
    end

    it 'ignores another instance under the same provider when an instance is pinned' do
      publish_scope_lane
      publish_scope_lane(instance: 'unknown', context: nil)
      claim_only(provider_family: 'vllm', instance_id: 'starting')

      expect_rejection(scope_router(routing: { provider: :vllm, instance: 'primary' }), kind: :context_rejected, status: 400)
    end

    it 'matches an instance-only pin against authoritative instance keys across providers' do
      publish_scope_lane
      add_unrelated_inventory

      expect_rejection(scope_router(routing: { instance: 'primary' }), kind: :context_rejected, status: 400)
    end

    it 'ignores complete lanes outside a hard tier pin' do
      publish_scope_lane(tier: :cloud)
      publish_scope_lane(provider: :ollama, instance: 'local', context: nil, tier: :local)

      expect_rejection(scope_router(routing: { tier: :cloud }), kind: :context_rejected, status: 400)
    end

    it 'ignores context-unknown embedding lanes when chat candidates exist inside the pin scope' do
      publish_scope_lane
      publish_scope_lane(instance: 'embedding', model: 'embed-model', context: nil, supported: [:embed])

      expect_rejection(scope_router(routing: { provider: :vllm }), kind: :context_rejected, status: 400)
    end

    it 'does not report an unrelated unavailable provider instead of the pinned context failure' do
      publish_scope_lane
      token = publish_scope_lane(provider: :ollama, instance: 'offline', model: 'unrelated', context: 200_000)
      mark_unavailable(provider_family: 'ollama', instance_id: 'offline', publisher_token_id: token.publisher_token_id)

      expect_rejection(scope_router(routing: { provider: :vllm }), kind: :context_rejected, status: 400)
    end
  end

  describe 'genuinely incomplete publication authority' do
    it 'keeps a matching provider initializing scope retryable' do
      publish_scope_lane
      claim_only(provider_family: 'vllm', instance_id: 'starting')

      expect_rejection(scope_router(routing: { provider: :vllm }), kind: :too_early, status: 425)
    end

    it 'cannot exclude an initializing provider by a model-only pin' do
      publish_scope_lane
      claim_only(provider_family: 'ollama', instance_id: 'starting')

      expect_rejection(scope_router(routing: { model: 'bounded-model' }), kind: :too_early, status: 425)
    end

    it 'cannot infer a tier from an initializing publication key' do
      publish_scope_lane(tier: :cloud)
      claim_only(provider_family: 'ollama', instance_id: 'starting')

      expect_rejection(scope_router(routing: { tier: :cloud }), kind: :too_early, status: 425)
    end

    it 'keeps an initializing exact instance retryable despite unrelated complete scopes' do
      claim_only(provider_family: 'vllm', instance_id: 'primary')
      publish_scope_lane(provider: :ollama, instance: 'unrelated', context: nil)

      expect_rejection(scope_router(routing: { provider: :vllm, instance: 'primary' }), kind: :too_early, status: 425)
    end

    it 'keeps a cold pinned catalog retryable' do
      expect_rejection(scope_router(routing: { provider: :vllm }), kind: :too_early, status: 425)
    end
  end

  describe 'missing pins' do
    it 'reports a missing model in a complete provider scope despite unrelated initializing scopes' do
      publish_scope_lane
      claim_only(provider_family: 'ollama', instance_id: 'starting')

      expect_rejection(scope_router(routing: { provider: :vllm, instance: 'primary', model: 'absent-model' }), kind: :invalid_request, status: 400)
    end

    it 'reports a missing exact instance in a non-cold catalog despite unrelated initialization' do
      publish_scope_lane
      claim_only(provider_family: 'ollama', instance_id: 'starting')

      expect_rejection(scope_router(routing: { provider: :vllm, instance: 'absent' }), kind: :invalid_request, status: 400)
    end

    it 'keeps a missing model retryable when a relevant provider has not published yet' do
      publish_scope_lane
      claim_only(provider_family: 'vllm', instance_id: 'starting')

      expect_rejection(scope_router(routing: { provider: :vllm, model: 'absent-model' }), kind: :too_early, status: 425)
    end
  end

  describe 'rejection precedence inside the requested scope' do
    it 'keeps all operation-unsupported evidence authoritative inside the pin scope' do
      publish_scope_lane(supported: [:embed], context: nil)
      add_unrelated_inventory

      expect_rejection(scope_router(routing: { provider: :vllm }), kind: :failed_dependency, status: 424)
    end

    it 'preserves policy denial despite unrelated allowed and initializing scopes' do
      publish_scope_lane
      add_unrelated_inventory
      Legion::Settings[:extensions][:llm][:vllm] = { instances: { primary: { model_blacklist: ['bounded-model'] } } }

      expect_rejection(scope_router(routing: { provider: :vllm }), kind: :policy_denied, status: 403)
    end

    it 'preserves authoritative unsupported capabilities despite unrelated capable scopes' do
      publish_scope_lane(capabilities: { tools: :unsupported })
      add_unrelated_inventory
      tools = [Legion::LLM::Types::ToolDefinition.build(name: 'lookup')]

      expect_rejection(scope_router(routing: { provider: :vllm }, tools: tools), kind: :failed_dependency, status: 424)
    end

    it 'preserves a pinned unavailable instance before unknown evidence' do
      token = publish_scope_lane(context: 200_000)
      mark_unavailable(provider_family: 'vllm', instance_id: 'primary', publisher_token_id: token.publisher_token_id)
      add_unrelated_inventory

      expect_rejection(scope_router(routing: { provider: :vllm }), kind: :service_unavailable, status: 503)
    end

    it 'preserves settled unknown capability rejection without unrelated initialization' do
      publish_scope_lane(context: 200_000, capabilities: {})
      add_unrelated_inventory
      tools = [Legion::LLM::Types::ToolDefinition.build(name: 'lookup')]

      expect_rejection(scope_router(routing: { provider: :vllm }, tools: tools), kind: :invalid_request, status: 400)
    end
  end
end
