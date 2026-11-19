# frozen_string_literal: true

require_relative 'matrix_helper'

RSpec.describe '[matrix] dispatch constraints and execution evidence', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before { MatrixHelper.configure_for_fake! }
  after { MatrixHelper.restore_started_state! }

  {
    '/v1/messages'         => { max_tokens: 64, stop_sequences: ['STOP'], messages: [{ role: 'user', content: 'Continue.' }] },
    '/v1/chat/completions' => { max_tokens: 64, stop: ['STOP'], messages: [{ role: 'user', content: 'Continue.' }] },
    '/v1/responses'        => { max_output_tokens: 64, input: [{ role: 'user', content: 'Continue.' }] }
  }.each do |path, payload|
    [false, true].each do |stream|
      it "preserves the token cap and stop sequences through #{path}, stream=#{stream}" do
        captured = []
        operation = stream ? :stream_chat : :chat
        allow(FakeProvider.adapter).to receive(operation).and_wrap_original do |original, messages, **options, &block|
          captured << options
          original.call(messages, **options, &block)
        end

        FakeProvider.with_scenario(stream ? :stream_text : :text) do
          post path, Legion::JSON.dump(payload.merge(model: MatrixHelper::FAKE_MODEL, temperature: 0, stream: stream)),
               'CONTENT_TYPE' => 'application/json'
        end

        expect(last_response.status).to eq(200)
        expect(captured).not_to be_empty
        captured.each do |options|
          params = options[:params].to_h
          expect(params[:max_tokens]).to eq(64)
          expect(params[:stop_sequences]).to eq(['STOP']) if payload.key?(:stop) || payload.key?(:stop_sequences)
          expect(options[:temperature] || params[:temperature]).to eq(0)
        end
      end

      it "counts actual server executions in the completion summary for #{path}, stream=#{stream}" do
        MatrixHelper.register_legion_tool!
        counts = []
        timelines = []
        allow_any_instance_of(app).to receive(:api_tool_execution_count).and_wrap_original do |original, response|
          timelines << response.timeline.map { |event| event[:key] }
          original.call(response).tap { |count| counts << count }
        end
        expect(MatrixHelper::FakeLegionEcho).to receive(:call).once.and_call_original

        FakeProvider.with_scenario(:server_tool_legion) do
          post path, Legion::JSON.dump(payload.merge(model: MatrixHelper::FAKE_MODEL, stream: stream)),
               'CONTENT_TYPE' => 'application/json'
        end

        expect(last_response.status).to eq(200)
        expect(counts).to eq([1]), "execution counts=#{counts.inspect}; timelines=#{timelines.inspect}"
      ensure
        MatrixHelper.unregister_legion_tool!
      end
    end
  end
end
