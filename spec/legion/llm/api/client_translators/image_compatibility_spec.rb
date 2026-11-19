# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_chat'
require 'legion/llm/api/client_translators/openai_responses'

RSpec.describe 'Client image normalization' do
  {
    jpeg_alias:       ['image/jpg', 'QUJDREVGRw==', 'image/jpeg'],
    mixed_case:       ['image/JPEG', 'QUJDREVGRw==', 'image/jpeg'],
    other_image_type: ['image/heic', 'QUJDREVGRw==', 'image/heic'],
    unpadded:         ['image/png', 'QUJDREVGRw', 'image/png'],
    wrapped:          ['image/png', "QUJD\r\nREVG\tRw== ", 'image/png']
  }.each do |name, (mime, data, normalized_mime)|
    it "normalizes #{name} through all client dialects without changing the caller's input" do
      translators = Legion::LLM::API::ClientTranslators
      cases = [
        [translators::AnthropicMessages, :messages, { type: 'image', source: { type: 'base64', media_type: mime, data: data } }],
        [translators::OpenAIChat, :messages, { type: 'image_url', image_url: { url: "data:#{mime};base64,#{data}" } }],
        [translators::OpenAIResponses, :input, { type: 'input_image', image_url: "data:#{mime};base64,#{data}" }]
      ]
      cases.each do |klass, key, block|
        translator = klass.new
        body = { key => [{ role: 'user', content: [block] }] }
        original = Legion::JSON.dump(body)
        parsed = translator.parse_request(body, {})
        request = translator.build_inference_request(parsed, request_id: 'image-compat', server_caller: { source: 'test' })

        image = request.messages.first.content.first
        expect(image.to_h).to include(type: :image, source_type: :base64, media_type: normalized_mime, data: 'QUJDREVGRw==')
        expect(Legion::JSON.dump(body)).to eq(original)
      end
    end
  end
end
