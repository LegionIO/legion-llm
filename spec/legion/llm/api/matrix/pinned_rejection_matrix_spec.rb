# frozen_string_literal: true

require_relative 'matrix_helper'

RSpec.describe '[matrix] pinned rejection scope', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }
  let(:requirements) { [] }

  before do
    MatrixHelper.configure_for_fake!
    Legion::Extensions::Llm::Inventory::Registry.reset!
    SsotV3SnapshotFactory.activate(
      provider_family: 'unrelated', instance_id: 'unknown', drafts: [
        SsotV3SnapshotFactory.offering_draft(model: 'unrelated-model', supported: %i[chat stream_chat], context: nil,
                                             capabilities: { streaming: :supported, thinking: :unknown })
      ]
    )
    SsotV3SnapshotFactory.claim_only(provider_family: 'starting', instance_id: 'pending')
    allow(FakeProvider.adapter).to receive(:chat).and_call_original
    allow(FakeProvider.adapter).to receive(:stream_chat).and_call_original
    allow(Legion::LLM::Router).to receive(:new).and_wrap_original do |original, **arguments|
      original.call(**arguments).tap { |router| requirements << router.required_capabilities }
    end
  end

  after { MatrixHelper.restore_started_state! }

  def publish_target(context:, thinking:)
    drafts = [SsotV3SnapshotFactory.offering_draft(
      model: MatrixHelper::FAKE_MODEL, supported: %i[chat stream_chat], context: context, max_output: 16_384,
      capabilities: { streaming: :supported, tools: :supported, thinking: thinking }
    )]
    if @target_publisher
      @target_sequence += 1
      result = Legion::Extensions::Llm::Inventory::Registry.replace_instance_snapshot(
        publisher_token: @target_publisher,
        instance_key: SsotV3SnapshotFactory.instance_key(provider_family: 'fake', instance_id: 'test'),
        offerings: drafts, sequence: @target_sequence
      )
      expect(result.applied).to be(true)
    else
      @target_sequence = 0
      @target_publisher = SsotV3SnapshotFactory.activate(
        provider_family: 'fake', instance_id: 'test', callable: FakeProvider.adapter, drafts: drafts
      )
    end
  end

  def request_body(path:, stream:, output:, thinking:)
    body = { model: MatrixHelper::FAKE_MODEL, stream: stream }
    case path
    when '/v1/messages'
      body.merge!(max_tokens: output, messages: [{ role: 'user', content: 'Hello.' }])
      body[:thinking] = { type: 'enabled', budget_tokens: 2048 } if thinking
    when '/v1/chat/completions'
      body.merge!(max_tokens: output, messages: [{ role: 'user', content: 'Hello.' }])
      body[:reasoning_effort] = 'medium' if thinking
    when '/v1/responses'
      body.merge!(max_output_tokens: output, input: [{ role: 'user', content: 'Hello.' }])
      body[:reasoning] = { effort: 'medium' } if thinking
    end
    body
  end

  %w[/v1/messages /v1/chat/completions /v1/responses].each do |path|
    [false, true].each do |stream|
      { context: 400, unknown_thinking: 400, unsupported_thinking: 424 }.each do |failure, status|
        it "returns a terminal JSON #{status} for #{failure} at #{path}, stream=#{stream}, before provider dispatch" do
          context = failure == :context ? 128_000 : 200_000
          thinking = { context: :supported, unknown_thinking: :unknown, unsupported_thinking: :unsupported }.fetch(failure)
          output = failure == :context ? 128_000 : 4096
          publish_target(context: context, thinking: thinking)
          body = request_body(path: path, stream: stream, output: output, thinking: failure != :context)
          headers = { 'CONTENT_TYPE' => 'application/json', 'HTTP_X_LEGION_PROVIDER' => 'fake',
                      'HTTP_X_LEGION_MODEL' => MatrixHelper::FAKE_MODEL }

          post path, Legion::JSON.dump(body), headers

          expect(requirements.last).to include(:thinking) unless failure == :context
          expect(last_response.status).to eq(status)
          expect(last_response.content_type).to start_with('application/json')
          expect(Legion::JSON.load(last_response.body)[:error]).to be_a(Hash)
          expect(last_response.headers['retry-after']).to be_nil
          expect(FakeProvider.adapter).not_to have_received(:chat)
          expect(FakeProvider.adapter).not_to have_received(:stream_chat)

          publish_target(context: context, thinking: :supported)
          healthy = request_body(path: path, stream: stream, output: 4096, thinking: failure != :context)
          FakeProvider.with_scenario(stream ? :stream_text : :text) do
            post path, Legion::JSON.dump(healthy), headers
          end
          expect(last_response.status).to eq(200)
          expect(FakeProvider.adapter).to have_received(stream ? :stream_chat : :chat).once
        end
      end
    end
  end

  describe 'Chat reasoning controls at real ingress and dispatch' do
    [false, true].each do |stream|
      Legion::Extensions::Llm::Canonical::Thinking::Config::EFFORT_LEVELS.each do |effort|
        it "dispatches the explicit #{effort} effort unchanged, stream=#{stream}" do
          publish_target(context: 200_000, thinking: :supported)
          captured = []
          operation = stream ? :stream_chat : :chat
          allow(FakeProvider.adapter).to receive(operation).and_wrap_original do |original, messages, **options, &consumer|
            captured << options.fetch(:thinking)
            original.call(messages, **options, &consumer)
          end
          body = request_body(path: '/v1/chat/completions', stream: stream, output: 4096, thinking: false)
          body[:reasoning_effort] = effort

          FakeProvider.with_scenario(stream ? :stream_text : :text) do
            post '/v1/chat/completions', Legion::JSON.dump(body),
                 'CONTENT_TYPE' => 'application/json', 'HTTP_X_LEGION_PROVIDER' => 'fake'
          end

          expect(last_response.status).to eq(200)
          expect(captured).to contain_exactly(have_attributes(effort: effort, budget: nil))
        end
      end

      ['unrecognized', '', 3, false].each do |effort|
        it "rejects invalid Chat effort #{effort.inspect} before execution, stream=#{stream}" do
          publish_target(context: 200_000, thinking: :supported)
          expect(Legion::LLM::Inference::Executor).not_to receive(:new)
          body = request_body(path: '/v1/chat/completions', stream: stream, output: 4096, thinking: false)
          body[:reasoning_effort] = effort

          post '/v1/chat/completions', Legion::JSON.dump(body), 'CONTENT_TYPE' => 'application/json'

          expect(last_response.status).to eq(400)
          expect(last_response.content_type).to start_with('application/json')
          expect(Legion::JSON.load(last_response.body).dig(:error, :type)).to eq('invalid_request_error')
          expect(FakeProvider.adapter).not_to have_received(:chat)
          expect(FakeProvider.adapter).not_to have_received(:stream_chat)
        end
      end
    end
  end
end
