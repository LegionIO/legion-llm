# frozen_string_literal: true

require_relative 'matrix_helper'
require 'legion/extensions/llm/vllm/translator'
require 'legion/extensions/llm/openai/translator'
require 'legion/extensions/llm/bedrock/translator'

RSpec.describe '[matrix] configured output budgets', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }
  let(:dispatches) { [] }
  let(:routers) { [] }
  let(:responses) { [] }

  before do
    MatrixHelper.configure_for_fake!
    allow(Legion::LLM::Router).to receive(:new).and_wrap_original do |original, **args|
      original.call(**args).tap { |router| routers << [args.fetch(:request), router] }
    end
    allow_any_instance_of(Legion::LLM::Inference::Executor).to receive(:build_response).and_wrap_original do |original|
      original.call.tap { |response| responses << response }
    end
  end
  after { MatrixHelper.restore_started_state! }

  def publish_output_lane(max_output:, instance_id: 'test', weight: 100)
    SsotV3SnapshotFactory.activate(
      provider_family: 'fake', instance_id: instance_id, callable: FakeProvider.adapter,
      drafts: [SsotV3SnapshotFactory.offering_draft(
        model: MatrixHelper::FAKE_MODEL, supported: %i[chat stream_chat],
        capabilities: { streaming: :supported, tools: :supported, thinking: :supported },
        context: 200_000, max_output: max_output,
        weight_inputs: { tier: 1, provider: 1, instance: weight, model_or_offering: 1 }, base_weight: weight
      )]
    )
  end

  def capture_dispatches(stream:, fail_first: false)
    operation = stream ? :stream_chat : :chat
    allow(FakeProvider.adapter).to receive(operation).and_wrap_original do |original, messages, **options, &block|
      dispatches << Legion::Extensions::Llm::Canonical::Request.build(
        messages: messages, params: options.fetch(:params), stream: stream,
        metadata: { model: MatrixHelper::FAKE_MODEL }
      )
      raise Legion::Extensions::Llm::OverloadedError.new(nil, 'temporary overload') if fail_first && dispatches.one?

      original.call(messages, **options, &block)
    end
  end

  def expect_rendered_limits(expected_limits)
    expect(dispatches.map { |request| request.params.max_tokens }).to eq(expected_limits)
    dispatches.zip(expected_limits).each do |request, limit|
      expect(Legion::Extensions::Llm::Vllm::Translator.new.render_request(request)[:max_tokens]).to eq(limit)
      expect(Legion::Extensions::Llm::Openai::Translator.new.render_request(request)[:max_tokens]).to eq(limit)
      bedrock = Legion::Extensions::Llm::Bedrock::Translator.new.render_request(request, target: :converse)
      expect(bedrock.dig(:inference_config, :max_tokens)).to eq(limit)
    end
  end

  def expect_reserved_limit(limit)
    expect(routers).not_to be_empty
    routers.each do |request, router|
      expect(request.tokens[:max]).to eq(limit)
      expect(router.required_output_tokens).to eq(limit)
      expect(router.context_budget).to eq(router.input_bound + limit)
    end
  end

  def output_limit_events
    responses.last.timeline.select { |event| event[:key] == 'provider:output_limit' }.map { |event| event.fetch(:data) }
  end

  [
    ['/v1/messages', :max_tokens, { messages: [{ role: 'user', content: 'Hello.' }] }],
    ['/v1/chat/completions', :max_tokens, { messages: [{ role: 'user', content: 'Hello.' }] }],
    ['/v1/chat/completions', :max_completion_tokens, { messages: [{ role: 'user', content: 'Hello.' }] }],
    ['/v1/responses', :max_output_tokens, { input: 'Hello.' }]
  ].each do |path, limit_key, payload|
    [false, true].each do |stream|
      [[nil, 12_345, 32_768], [128, 12_345, 16_384], [nil, nil, 16_384],
       [64_000, nil, 16_384], [16_384, nil, 16_384], [64_000, nil, 128_000],
       [64_000, nil, nil], [nil, nil, nil]].each do |explicit_limit, configured_limit, native_limit|
        it "bounds #{path} #{limit_key}=#{explicit_limit.inspect}, configured=#{configured_limit.inspect}, native=#{native_limit.inspect}, stream=#{stream}" do
          Legion::Settings[:llm][:max_output_tokens] = configured_limit if configured_limit
          requested_limit = explicit_limit || configured_limit || 64_000
          expected_limit = native_limit ? [requested_limit, native_limit].min : requested_limit
          Legion::Extensions::Llm::Inventory::Registry.reset!
          publish_output_lane(max_output: native_limit)
          capture_dispatches(stream: stream)

          body = payload.merge(model: MatrixHelper::FAKE_MODEL, stream: stream)
          body[limit_key] = explicit_limit if explicit_limit
          FakeProvider.with_scenario(stream ? :stream_text : :text) do
            post path, Legion::JSON.dump(body), 'CONTENT_TYPE' => 'application/json'
          end

          # Messages requires a client max_tokens on the wire. Preserve that
          # validation; the omitted-limit default applies to accepted requests.
          if path == '/v1/messages' && explicit_limit.nil?
            expect(last_response.status).to eq(400)
            expect(routers).to be_empty
            expect(dispatches).to be_empty
            next
          end

          expect(last_response.status).to eq(200)
          expect_reserved_limit(requested_limit)
          expect_rendered_limits([expected_limit])
          expect(output_limit_events).to contain_exactly(include(
                                                           requested_max_tokens: requested_limit, effective_max_tokens: expected_limit,
                                                           native_max_tokens: native_limit, source: native_limit ? :provider_catalog : :absent,
                                                           attempt_number: 1, inventory_generation: be_a(Integer), lane_id: be_a(String)
                                                         ))
        end
      end

      [[16_384, 32_768], [32_768, 8192]].each do |first_limit, next_limit|
        it "recomputes #{path} output from the original ceiling after #{first_limit}->#{next_limit} failover, stream=#{stream}" do
          Legion::Extensions::Llm::Inventory::Registry.reset!
          publish_output_lane(max_output: first_limit, instance_id: 'primary', weight: 100)
          publish_output_lane(max_output: next_limit, instance_id: 'secondary', weight: 50)
          capture_dispatches(stream: stream, fail_first: true)

          FakeProvider.with_scenario(stream ? :stream_text : :text) do
            post path, Legion::JSON.dump(payload.merge(model: MatrixHelper::FAKE_MODEL, limit_key => 64_000, stream: stream)),
                 'CONTENT_TYPE' => 'application/json'
          end

          expect(last_response.status).to eq(200)
          expect_reserved_limit(64_000)
          expect_rendered_limits([first_limit, next_limit])
          expect(output_limit_events.map { |event| event.values_at(:requested_max_tokens, :effective_max_tokens, :attempt_number) })
            .to eq([[64_000, first_limit, 1], [64_000, next_limit, 2]])
        end
      end

      it "keeps the selected ceiling through server-tool continuation at #{path}, stream=#{stream}" do
        MatrixHelper.register_legion_tool!
        capture_dispatches(stream: stream)

        FakeProvider.with_scenario(:server_tool_legion) do
          post path, Legion::JSON.dump(payload.merge(model: MatrixHelper::FAKE_MODEL, limit_key => 64_000, stream: stream)),
               'CONTENT_TYPE' => 'application/json'
        end

        expect(last_response.status).to eq(200)
        expect_reserved_limit(64_000)
        expect(dispatches.map { |request| request.params.max_tokens }).to eq([16_384, 16_384])
        expect(output_limit_events.map { |event| event.values_at(:requested_max_tokens, :effective_max_tokens) })
          .to eq([[64_000, 16_384], [64_000, 16_384]])
      ensure
        MatrixHelper.unregister_legion_tool!
      end
    end
  end
end
