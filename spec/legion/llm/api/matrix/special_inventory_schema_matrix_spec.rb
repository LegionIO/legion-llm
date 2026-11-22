# frozen_string_literal: true

require_relative 'matrix_helper'

RSpec.describe '[matrix] zero-argument inventory and caller schema preservation', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before { MatrixHelper.configure_for_fake! }
  after { MatrixHelper.restore_started_state! }

  open_schema = { type: 'object', properties: {} }
  function = { name: 'open_record', description: 'Accept caller-defined properties', parameters: open_schema }
  {
    '/v1/messages'         => {
      max_tokens: 1024, messages: [{ role: 'user', content: 'List the special tools.' }],
      tools: [{ name: function[:name], description: function[:description], input_schema: open_schema }]
    },
    '/v1/chat/completions' => {
      max_tokens: 1024, messages: [{ role: 'user', content: 'List the special tools.' }],
      tools: [{ type: 'function', function: function }]
    },
    '/v1/responses'        => {
      max_output_tokens: 1024, input: 'List the special tools.', tools: [function.merge(type: 'function')]
    }
  }.each do |path, payload|
    [false, true].each do |stream|
      it "preserves both schemas through #{path}, stream=#{stream}" do
        captured = []
        allow(FakeProvider.adapter).to receive(stream ? :stream_chat : :chat).and_wrap_original do |original, messages, **options, &block|
          captured << options.fetch(:tools)
          original.call(messages, **options, &block)
        end

        FakeProvider.with_scenario(stream ? :stream_text : :text) do
          post path, Legion::JSON.dump(payload.merge(model: MatrixHelper::FAKE_MODEL, stream: stream)),
               'CONTENT_TYPE' => 'application/json'
        end

        expect(last_response.status).to eq(200)
        expect(captured.size).to eq(1)
        tools = captured.first
        expect(tools.fetch(:legion_list_special_tools).parameters)
          .to eq(type: 'object', properties: {}, additionalProperties: false)
        expect(tools.fetch(:open_record).parameters).to eq(open_schema)
      end
    end
  end
end
