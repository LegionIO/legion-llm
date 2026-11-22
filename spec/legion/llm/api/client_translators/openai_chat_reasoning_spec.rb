# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/openai_chat'

RSpec.describe Legion::LLM::API::ClientTranslators::OpenAIChat do
  let(:translator) { described_class.new }

  Legion::Extensions::Llm::Canonical::Thinking::Config::EFFORT_LEVELS.each do |effort|
    it "preserves explicit #{effort} effort through canonical JSON and inference without inventing a budget" do
      canonical = translator.parse_request(messages: [{ role: 'user', content: 'Hello.' }], reasoning_effort: effort)
      restored = Legion::Extensions::Llm::Canonical::Request.from_hash(Legion::JSON.load(Legion::JSON.dump(canonical)))
      request = translator.build_inference_request(restored, request_id: 'chat-reasoning', server_caller: { source: 'test' })

      [canonical.thinking, restored.thinking, request.thinking].each do |thinking|
        expect(thinking).to be_a(Legion::Extensions::Llm::Canonical::Thinking::Config)
        expect(thinking.effort).to eq(effort)
        expect(thinking.budget).to be_nil
        expect(thinking.to_h).not_to have_key(:budget)
      end
    end
  end

  [{}, { reasoning_effort: nil }].each do |input|
    it "preserves absent thinking for #{input.inspect}" do
      canonical = translator.parse_request({ messages: [{ role: 'user', content: 'Hello.' }] }.merge(input))
      request = translator.build_inference_request(canonical, request_id: 'chat-without-reasoning', server_caller: {})

      expect(canonical.thinking).to be_nil
      expect(request.thinking).to be_nil
    end
  end

  ['unrecognized', '', 3, false].each do |effort|
    it "rejects invalid effort #{effort.inspect} with the canonical validation cause" do
      expect do
        translator.parse_request(messages: [{ role: 'user', content: 'Hello.' }], reasoning_effort: effort)
      end.to raise_error(Legion::LLM::Errors::InvalidRequest) { |error| expect(error.cause).to be_a(ArgumentError) }
    end
  end
end
