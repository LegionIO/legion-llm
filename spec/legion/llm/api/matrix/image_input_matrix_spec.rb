# frozen_string_literal: true

require_relative 'matrix_helper'

RSpec.describe '[matrix] image input rejection', type: :request do
  include Rack::Test::Methods

  let(:app) { MatrixHelper.app_class }

  before { MatrixHelper.configure_for_fake! }
  after { MatrixHelper.restore_started_state! }

  {
    '/v1/messages'         => {
      malformed: { messages: [{ role: 'user', content: [{ type: 'image', source: { type: 'url', url: 'file:///tmp/image.png' } }] }] },
      file:      { messages: [{ role: 'user', content: [{ type: 'image', source: { type: 'file', file_id: 'file-image' } }] }] }
    },
    '/v1/chat/completions' => {
      malformed: { messages: [{ role: 'user', content: [{ type: 'image_url', image_url: { url: 'file:///tmp/image.png' } }] }] },
      file:      { messages: [{ role: 'user', content: [{ type: 'image_url', file_id: 'file-image' }] }] }
    },
    '/v1/responses'        => {
      malformed: { input: [{ role: 'user', content: [{ type: 'input_image', image_url: 'file:///tmp/image.png' }] }] },
      file:      { input: [{ role: 'user', content: [{ type: 'input_image', file_id: 'file-image' }] }] }
    }
  }.each do |path, inputs|
    context path do
      it 'returns a caller-correctable error for an unsupported image URL scheme' do
        payload = inputs[:malformed].merge(model: 'fake-default', max_tokens: 64)
        post path, Legion::JSON.dump(payload), { 'CONTENT_TYPE' => 'application/json' }

        expect(last_response.status).to eq(400)
        expect(Legion::JSON.load(last_response.body).dig(:error, :type)).to eq('invalid_request_error')
      end

      it 'rejects provider-specific image files before opening a requested event stream' do
        payload = inputs[:file].merge(model: 'fake-default', max_tokens: 64, stream: true)
        post path, Legion::JSON.dump(payload), { 'CONTENT_TYPE' => 'application/json' }

        expect(last_response.status).to eq(400)
        expect(last_response.content_type).to start_with('application/json')
        expect(Legion::JSON.load(last_response.body).dig(:error, :type)).to eq('invalid_request_error')
      end
    end
  end
end
