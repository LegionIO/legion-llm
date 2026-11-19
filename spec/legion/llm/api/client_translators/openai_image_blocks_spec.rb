# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/openai_responses'
require 'legion/llm/api/client_translators/openai_chat'
require 'legion/extensions/llm/vllm/translator'

RSpec.describe 'OpenAI image ingress' do
  let(:responses) { Legion::LLM::API::ClientTranslators::OpenAIResponses.new }
  let(:chat) { Legion::LLM::API::ClientTranslators::OpenAIChat.new }
  let(:image_url) { 'https://example.com/screenshot.png' }
  let(:data_url) { 'data:image/jpeg;base64,QUJDREVGRw==' }

  def image_inference_request(translator:, blocks:)
    message = { role: 'user', content: blocks }
    body = translator == responses ? { input: [message] } : { messages: [message] }
    request = translator.parse_request(body, {})
    translator.build_inference_request(request, request_id: 'image-test', server_caller: { source: 'test' })
  end

  def image_wire_messages(request:)
    canonical = Legion::Extensions::Llm::Canonical::Request.build(
      messages: request.messages, metadata: { model: 'vision-model' }
    )
    Legion::Extensions::Llm::Vllm::Translator.new.render_request(canonical)[:messages]
  end

  it 'retains Responses URL/data images, order and detail through inference and real vLLM rendering without mutation' do
    blocks = Legion::JSON.load(Legion::JSON.dump([
                                                   { type: 'input_text', text: 'compare' },
                                                   { type: 'input_image', image_url: image_url, detail: 'low' },
                                                   { type: 'input_image', image_url: data_url, detail: 'high' },
                                                   { type: 'input_text', text: 'these' }
                                                 ]))
    original = Legion::JSON.dump(blocks)
    request = image_inference_request(translator: responses, blocks: blocks)

    expect(image_wire_messages(request: request)).to eq([
                                                          { role: 'user', content: [
                                                            { type: 'text', text: 'compare' },
                                                            { type: 'image_url', image_url: { url: image_url, detail: 'low' } },
                                                            { type: 'image_url', image_url: { url: data_url, detail: 'high' } },
                                                            { type: 'text', text: 'these' }
                                                          ] }
                                                        ])
    expect(request.messages.first.content.select { |block| block.type == :image }.map(&:detail)).to eq(%w[low high])
    expect(request.messages.first.text).to eq('comparethese')
    expect(Legion::JSON.dump(blocks)).to eq(original)
  end

  it 'preserves nested Chat detail and direct string-key image envelopes without mutation' do
    blocks = [
      { 'type' => 'text', 'text' => 'compare' },
      { 'type' => 'image_url', 'image_url' => { 'url' => data_url, 'detail' => 'high' } },
      { 'type' => 'image_url', 'image_url' => { 'url' => image_url, 'detail' => 'low' } }
    ]
    original = Legion::JSON.dump(blocks)
    request = image_inference_request(translator: chat, blocks: blocks)

    expect(image_wire_messages(request: request)).to eq([
                                                          { role: 'user', content: [
                                                            { type: 'text', text: 'compare' },
                                                            { type: 'image_url', image_url: { url: data_url, detail: 'high' } },
                                                            { type: 'image_url', image_url: { url: image_url, detail: 'low' } }
                                                          ] }
                                                        ])
    expect(request.messages.first.content.drop(1).map(&:detail)).to eq(%w[high low])
    expect(Legion::JSON.dump(blocks)).to eq(original)
  end

  it 'keeps symbolized Chat detail and HTTP image sources' do
    request = image_inference_request(translator: chat, blocks: [
                                        { type: 'image_url', image_url: { url: 'http://example.com/image.gif', detail: 'high' } }
                                      ])

    expect(image_wire_messages(request: request)).to eq([
                                                          { role: 'user', content: [{ type: 'image_url', image_url: { url: 'http://example.com/image.gif', detail: 'high' } }] }
                                                        ])
    expect(request.messages.first.content.first.detail).to eq('high')
  end

  {
    'absent URL'                 => nil,
    'empty URL'                  => '',
    'non-string URL'             => 12,
    'relative URL'               => '/image.png',
    'non-HTTP URL'               => 'ftp://example.com/image.png',
    'hostless URL'               => 'https:/image.png',
    'invalid URL'                => 'https://exa mple.com/image.png',
    'missing data URL delimiter' => 'data:image/png;base64',
    'non-base64 data URL'        => 'data:image/png,QUJD',
    'missing image MIME'         => 'data:;base64,QUJD',
    'unsupported image MIME'     => 'data:text/plain;base64,QUJD',
    'empty base64 payload'       => 'data:image/png;base64,',
    'invalid base64 alphabet'    => 'data:image/png;base64,!!!!',
    'invalid base64 padding'     => 'data:image/png;base64,A===',
    'truncated base64 payload'   => 'data:image/png;base64,QUJ'
  }.each do |description, url|
    it "rejects #{description} in both OpenAI image dialects" do
      [[responses, { type: 'input_image', image_url: url }],
       [chat, { type: 'image_url', image_url: { url: url } }]].each do |translator, block|
        expect do
          image_inference_request(translator: translator, blocks: [block])
        end.to raise_error(Legion::LLM::Errors::InvalidRequest)
      end
    end
  end

  it 'rejects provider file references rather than silently dropping or manufacturing an image URL' do
    [[responses, { type: 'input_image', file_id: 'file-123' }],
     [responses, { type: 'input_image', file_id: 'file-123', image_url: image_url }],
     [chat, { type: 'image_url', image_url: { file_id: 'file-123', url: image_url } }]].each do |translator, block|
      expect do
        image_inference_request(translator: translator, blocks: [block])
      end.to raise_error(Legion::LLM::Errors::InvalidRequest)
    end
  end

  it 'rejects image_generation_call history rather than silently skipping the generated image' do
    expect do
      responses.parse_request({ input: [
                                { type: 'image_generation_call', id: 'ig-123', result: 'QUJD', status: 'completed' },
                                { role: 'user', content: 'describe the generated image' }
                              ] }, {})
    end.to raise_error(Legion::LLM::Errors::InvalidRequest)
  end

  it 'rejects generated-image items nested in message content' do
    expect do
      image_inference_request(translator: responses, blocks: [{ type: 'image_generation_call', result: 'QUJD' }])
    end.to raise_error(Legion::LLM::Errors::InvalidRequest)
  end
end
