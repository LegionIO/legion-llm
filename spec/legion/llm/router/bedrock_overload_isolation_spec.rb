# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/bedrock/helpers/callable'

RSpec.describe Legion::LLM::Router, 'Bedrock overload isolation', :ssot_v3 do
  def bedrock_router(model)
    request = Legion::LLM::Inference::Request.build_for_test(
      routing_seed: 'ab' * 16, messages: [], routing: { provider: :bedrock, instance: :capacity_test, model: model }
    )
    described_class.new(request: request, operation: :chat, body_model: nil)
  end

  it 'keeps every offering available to new requests after an AWS capacity error' do
    callable = Class.new(Legion::Extensions::Llm::Bedrock::Helpers::Callable) do
      def chat(_messages, **)
        raise Aws::BedrockRuntime::Errors::ServiceUnavailableException.new(
          Seahorse::Client::RequestContext.new, 'Temporary capacity constraint'
        )
      end
    end.new(instance_cfg: { bedrock_region: 'us-east-1' }, logger: Logger.new(File::NULL))

    models = %w[model-a model-b]
    drafts = models.map do |model|
      offering_draft(model: model, supported: %i[chat], context: 200_000, max_output: 16_384)
    end
    activate(provider_family: 'bedrock', instance_id: 'capacity_test', callable: callable, drafts: drafts)
    router = bedrock_router(models.first)
    attempt = router.next_attempt!
    generation = snapshot.generation
    result = Legion::LLM::Call::SelectionDispatch.call(attempt_context: attempt, arguments: { messages: [] })
    action = router.classify(dispatch_result: result, attempt_context: attempt)

    expect(result.outcome.kind).to eq(:overloaded)
    expect(action.global_transition).to be_nil
    expect(snapshot.generation).to eq(generation)
    expect(attempt.selection.callable_handle.reference_count).to eq(0)
    models.each do |model|
      selection = bedrock_router(model).next_lane
      expect(selection).to be_a(Legion::Extensions::Llm::Routing::Selection)
      expect(selection.model).to eq(model)
    end
  end
end
