# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/extensions/llm/vllm/translator'

RSpec.describe 'Anthropic image ingress' do
  let(:translator) { Legion::LLM::API::ClientTranslators::AnthropicMessages.new }
  let(:image_data) { 'QUJDREVGRw==' }
  let(:image_url) { 'https://example.com/screenshot.png' }
  let(:cache_control) { { type: 'ephemeral' } }
  let(:base64_image) do
    { type: 'image', source: { type: 'base64', media_type: 'image/png', data: image_data }, cache_control: cache_control }
  end
  let(:url_image) { { type: 'image', source: { type: 'url', url: image_url } } }

  def image_inference_request(messages:)
    request = translator.parse_request({ messages: messages }, {})
    translator.build_inference_request(request, request_id: 'image-test', server_caller: { source: 'test' })
  end

  def image_wire_messages(request:)
    canonical = Legion::Extensions::Llm::Canonical::Request.build(
      messages: request.messages, metadata: { model: 'vision-model' }
    )
    Legion::Extensions::Llm::Vllm::Translator.new.render_request(canonical)[:messages]
  end

  it 'keeps mixed text and images in one ordered user turn through inference and direct vLLM rendering' do
    blocks = [{ type: 'text', text: 'before' }, base64_image, url_image, { type: 'text', text: 'after' }]
    messages = [{ role: 'user', content: blocks }]
    original = Legion::JSON.dump(messages)
    request = image_inference_request(messages: messages)

    expect(image_wire_messages(request: request)).to eq([
                                                          { role: 'user', content: [
                                                            { type: 'text', text: 'before' },
                                                            { type: 'image_url', image_url: { url: "data:image/png;base64,#{image_data}" } },
                                                            { type: 'image_url', image_url: { url: image_url } },
                                                            { type: 'text', text: 'after' }
                                                          ] }
                                                        ])
    expect(request.messages.first.content[1].cache_control).to eq(cache_control)
    expect(request.messages.first.text).to eq('beforeafter')
    expect(Legion::JSON.dump(messages)).to eq(original)
  end

  it 'preserves nested tool-result images, tool association and real tool boundaries without mutating symbolized JSON' do
    messages = Legion::JSON.load(Legion::JSON.dump([
                                                     { role: 'assistant', content: [{ type: 'tool_use', id: 'capture-1', name: 'capture', input: {} }] },
                                                     { role: 'user', content: [
                                                       { type: 'text', text: 'context' }, url_image,
                                                       { type: 'tool_result', tool_use_id: 'capture-1', content: [
                                                         { type: 'text', text: 'capture' }, base64_image, url_image, { type: 'text', text: 'done' }
                                                       ] },
                                                       base64_image, { type: 'text', text: 'compare' }
                                                     ] }
                                                   ]))
    original = Legion::JSON.dump(messages)
    request = image_inference_request(messages: messages)
    wire = image_wire_messages(request: request)

    expect(wire.map { |message| message[:role] }).to eq(%w[assistant user tool user])
    expect(wire[2]).to eq(
      role: 'tool', tool_call_id: wire[0][:tool_calls].first[:id],
      content: [
        { type: 'text', text: 'capture' },
        { type: 'image_url', image_url: { url: "data:image/png;base64,#{image_data}" } },
        { type: 'image_url', image_url: { url: image_url } },
        { type: 'text', text: 'done' }
      ]
    )
    expect(wire[1][:content]).to eq([
                                      { type: 'text', text: 'context' }, { type: 'image_url', image_url: { url: image_url } }
                                    ])
    expect(wire[3][:content]).to eq([
                                      { type: 'image_url', image_url: { url: "data:image/png;base64,#{image_data}" } },
                                      { type: 'text', text: 'compare' }
                                    ])
    expect(request.messages[2].content[1].cache_control).to eq(cache_control)
    expect(request.messages[2].text).to eq('capturedone')
    expect(Legion::JSON.dump(messages)).to eq(original)
  end

  it 'accepts direct string-key image source envelopes at both nesting levels' do
    image = { 'type' => 'image', 'source' => { 'type' => 'base64', 'media_type' => 'image/webp', 'data' => image_data },
              'cache_control' => { 'type' => 'ephemeral' } }
    request = image_inference_request(messages: [
                                        { 'role' => 'user', 'content' => [image, { 'type' => 'tool_result', 'tool_use_id' => 'capture-2', 'content' => [image] }] }
                                      ])

    expect(image_wire_messages(request: request)).to eq([
                                                          { role: 'user', content: [{ type: 'image_url', image_url: { url: "data:image/webp;base64,#{image_data}" } }] },
                                                          { role: 'tool', tool_call_id: 'capture-2',
                                                            content: [{ type: 'image_url', image_url: { url: "data:image/webp;base64,#{image_data}" } }] }
                                                        ])
    expect(request.messages.map { |message| message.content.first.cache_control }).to eq([
                                                                                           { 'type' => 'ephemeral' }, { 'type' => 'ephemeral' }
                                                                                         ])
  end

  {
    'missing source'      => nil,
    'non-object source'   => 'image.png',
    'file source'         => { type: 'file', file_id: 'file-123' },
    'unknown source type' => { type: 'other', data: 'QUJD' },
    'missing MIME'        => { type: 'base64', data: 'QUJD' },
    'unsupported MIME'    => { type: 'base64', media_type: 'text/plain', data: 'QUJD' },
    'empty data'          => { type: 'base64', media_type: 'image/png', data: '' },
    'non-string data'     => { type: 'base64', media_type: 'image/png', data: 1234 },
    'invalid base64'      => { type: 'base64', media_type: 'image/png', data: 'not base64' },
    'relative URL'        => { type: 'url', url: '/image.png' },
    'non-HTTP URL'        => { type: 'url', url: 'file:///image.png' },
    'malformed URL'       => { type: 'url', url: 'https://exa mple.com/image.png' }
  }.each do |description, source|
    it "rejects #{description} at both top-level and tool-result ingress" do
      image = { type: 'image', source: source }
      [image, { type: 'tool_result', tool_use_id: 'capture', content: [image] }].each do |block|
        expect do
          image_inference_request(messages: [{ role: 'user', content: [block] }])
        end.to raise_error(Legion::LLM::Errors::InvalidRequest)
      end
    end
  end
end
