# frozen_string_literal: true

require_relative 'matrix_helper'

RSpec.describe '[matrix] canonical thinking usage preservation', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before { MatrixHelper.configure_for_fake! }
  after { MatrixHelper.restore_started_state! }

  {
    '/v1/messages'         => { max_tokens: 64, messages: [{ role: 'user', content: 'Hello.' }] },
    '/v1/chat/completions' => { max_tokens: 64, messages: [{ role: 'user', content: 'Hello.' }] },
    '/v1/responses'        => { max_output_tokens: 64, input: [{ role: 'user', content: 'Hello.' }] }
  }.each do |path, payload|
    [false, true].each do |stream|
      [17, 0, nil].each do |thinking_tokens|
        it "preserves reported thinking usage #{thinking_tokens.inspect} through #{path}, stream=#{stream}" do
          usage = Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: 10, output_tokens: 25, thinking_tokens: thinking_tokens)
          allow(FakeProvider::Fixtures).to receive(:usage).and_return(usage)
          observed_tokens = []
          metering_events = []
          allow(Legion::LLM::Inference::Steps::Metering).to receive(:build_event).and_wrap_original do |original, **options|
            original.call(**options).tap { |event| metering_events << event }
          end
          allow_any_instance_of(app).to receive(:api_tool_execution_count).and_wrap_original do |original, response|
            observed_tokens << response.tokens
            original.call(response)
          end

          FakeProvider.with_scenario(stream ? :stream_text : :text) do
            post path, Legion::JSON.dump(payload.merge(model: MatrixHelper::FAKE_MODEL, stream: stream)),
                 'CONTENT_TYPE' => 'application/json'
          end

          expect(last_response.status).to eq(200)
          expect(observed_tokens.size).to eq(1)
          expect(observed_tokens.first[:thinking_tokens]).to eq(thinking_tokens)
          expect(metering_events.size).to eq(1)
          expect(metering_events.first).to include(thinking_tokens: thinking_tokens.to_i, total_tokens: 35)
          next unless path == '/v1/responses'

          body = responses_body(stream)
          expect(body[:usage]).to include(input_tokens: 10, output_tokens: 25, total_tokens: 35)
          expect(body[:usage].dig(:output_tokens_details, :reasoning_tokens)).to eq(thinking_tokens)
          expect(body[:output]).not_to include(a_hash_including(type: 'reasoning'))
          expect(body[:output]).not_to include(a_hash_including(phase: 'reasoning'))
        end
      end
    end
  end

  def responses_body(stream)
    return Legion::JSON.load(last_response.body) unless stream

    events = last_response.body.lines.filter_map do |line|
      Legion::JSON.load(line.delete_prefix('data: ')) if line.start_with?('data: ')
    end
    events.find { |event| event[:type] == 'response.completed' }.fetch(:response)
  end
end
