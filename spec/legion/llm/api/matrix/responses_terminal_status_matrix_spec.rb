# frozen_string_literal: true

require_relative 'matrix_helper'

RSpec.describe '[matrix] Responses terminal status', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before { MatrixHelper.configure_for_fake! }
  after { MatrixHelper.restore_started_state! }

  {
    max_tokens:     ['incomplete', { reason: 'max_output_tokens' }],
    content_filter: ['incomplete', { reason: 'content_filter' }],
    end_turn:       ['completed', nil],
    nil => ['failed', nil]
  }.each do |stop_reason, (status, details)|
    [false, true].each do |stream|
      it "preserves #{stop_reason} in the response and message status, stream=#{stream}" do
        allow(FakeProvider::Fixtures).to receive(:text_response).and_wrap_original do |original, model|
          original.call(model).with(stop_reason: stop_reason)
        end
        allow(FakeProvider::Fixtures).to receive(:stream_text).and_wrap_original do |original, model, **options, &consumer|
          original.call(model, **options) do |chunk|
            consumer.call(chunk.type == :done ? chunk.with(stop_reason: stop_reason) : chunk)
          end.with(stop_reason: stop_reason)
        end

        FakeProvider.with_scenario(stream ? :stream_text : :text) do
          post '/v1/responses', Legion::JSON.dump(model: MatrixHelper::FAKE_MODEL, stream: stream,
                                                  max_output_tokens: 50, input: 'Say hello in exactly 3 words.'),
               'CONTENT_TYPE' => 'application/json'
        end

        expect(last_response.status).to eq(200)
        if stream
          events = MatrixHelper.parse_sse(last_response.body)
          terminal_events = events.slice('response.completed', 'response.incomplete', 'response.failed')
          expect(terminal_events.map(&:first)).to eq(["response.#{status}"])
          body = terminal_events.first.last.fetch(:response)
          done_item = events.find { |name, data| name == 'response.output_item.done' && data.dig(:item, :type) == 'message' }.last[:item]
          expect(body[:output]).to include(done_item)
        else
          body = Legion::JSON.load(last_response.body)
        end

        expect(body).to include(status: status, incomplete_details: details)
        message = body[:output].find { |item| item[:type] == 'message' }
        expect(message).to include(status: status == 'completed' ? 'completed' : 'incomplete')
        expect(message.dig(:content, 0, :text)).to eq('Hello there.')
      end
    end
  end
end
