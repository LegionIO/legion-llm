# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Selected native output limits', :ssot_v3 do
  it 'uses captured lane evidence after newer publication without changing ingress params or other dispatch controls' do
    activate(provider_family: 'vllm', instance_id: 'primary', drafts: [
               offering_draft(model: 'selected-model', context: 200_000, max_output: 16_384)
             ])
    request = Legion::LLM::Inference::Request.build(
      messages: [{ role: :user, content: 'Continue.' }], tokens: { max: 64_000 },
      generation: { temperature: 0, top_p: 0.7, seed: 42 }, stop: { sequences: ['STOP'] }
    )
    router = Legion::LLM::Router.new(request: request, operation: :chat, body_model: nil)
    attempt = router.next_attempt!
    executor = Legion::LLM::Inference::Executor.new(request)
    executor.send(:populate_ssot_v3_resolved_state, attempt)
    options = executor.send(:native_dispatch_options)
    original_params = options.fetch(:params).to_h

    activate(provider_family: 'vllm', instance_id: 'secondary', drafts: [
               offering_draft(model: 'newer-model', context: 200_000, max_output: 32_768)
             ])
    expect(Legion::Extensions::Llm::Inventory::Registry.snapshot.generation).to be > attempt.inventory_generation
    expect(Legion::Extensions::Llm::Inventory::Registry).not_to receive(:snapshot)

    _, projected = executor.send(:project_dispatch_arguments, messages: request.messages, options: options)
    expect(projected.fetch(:params).to_h).to eq(original_params.merge(max_tokens: 16_384))
    expect(options.fetch(:params).to_h).to eq(original_params)
    expect(request.tokens).to eq(max: 64_000)
    expect(router.required_output_tokens).to eq(64_000)
    event = executor.instance_variable_get(:@timeline).events.find { |entry| entry[:key] == 'provider:output_limit' }
    expect(event.fetch(:data)).to include(inventory_generation: attempt.inventory_generation, source: :provider_catalog)
    expect(Legion::LLM::Inference::AuditPublisher.compact_timeline([event])).to eq([event])
  end
end
