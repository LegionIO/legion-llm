# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/metering'
require 'legion/llm/deprecation'

RSpec.describe 'Deprecated _direct methods emit metering' do
  before do
    Legion::LLM::Deprecation.reset!
    Legion::Settings[:llm][:default_provider] = :anthropic
    Legion::Settings[:llm][:default_model] = 'claude-sonnet-4-6'
    Legion::Settings[:llm][:pipeline_enabled] = true
    stub_native_provider(content: 'governed response')
    allow(Legion::LLM::Metering).to receive(:emit).and_return(:spooled)
  end

  describe 'Legion::LLM.chat_direct (via Inference.chat_direct)' do
    it 'emits a deprecation warning' do
      expect(Legion::LLM::Deprecation).to receive(:warn_once).with(:chat_direct, replacement: 'Legion::LLM.chat').and_call_original
      Legion::LLM.chat_direct(message: 'hello', model: 'claude-sonnet-4-6', provider: :anthropic)
    end

    it 'routes through the governed pipeline which emits metering' do
      Legion::LLM.chat_direct(message: 'hello', model: 'claude-sonnet-4-6', provider: :anthropic)
      expect(Legion::LLM::Metering).to have_received(:emit).at_least(:once)
    end

    it 'metering event includes provider and model' do
      Legion::LLM.chat_direct(message: 'hello', model: 'claude-sonnet-4-6', provider: :anthropic)
      expect(Legion::LLM::Metering).to have_received(:emit).with(
        hash_including(provider: :anthropic, model_id: 'claude-sonnet-4-6')
      ).at_least(:once)
    end

    it 'returns a usable response (backwards compatibility)' do
      result = Legion::LLM.chat_direct(message: 'hello', model: 'claude-sonnet-4-6', provider: :anthropic)
      expect(result).not_to be_nil
    end
  end

  describe 'Legion::LLM.embed_direct' do
    let(:embed_result) do
      { result: [Array.new(1024, 0.1)], provider: :anthropic, model: 'embed-v1', tokens: 42 }
    end

    before do
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(embed_result)
    end

    it 'emits a deprecation warning' do
      expect(Legion::LLM::Deprecation).to receive(:warn_once).with(:embed_direct, replacement: 'Legion::LLM.embed').and_call_original
      Legion::LLM.embed_direct('test text')
    end

    it 'emits a metering event' do
      Legion::LLM.embed_direct('test text')
      expect(Legion::LLM::Metering).to have_received(:emit).with(
        hash_including(
          request_type: 'embedding',
          event_type:   'llm_embedding',
          tier:         'direct',
          status:       'success'
        )
      )
    end

    it 'metering event includes token count from result' do
      Legion::LLM.embed_direct('test text')
      expect(Legion::LLM::Metering).to have_received(:emit).with(
        hash_including(input_tokens: 42, total_tokens: 42)
      )
    end

    it 'returns the embedding result unchanged' do
      result = Legion::LLM.embed_direct('test text')
      expect(result).to eq(embed_result)
    end
  end

  describe 'Legion::LLM.structured_direct' do
    let(:schema) { { type: 'object', properties: { name: { type: 'string' } } } }
    let(:structured_result) do
      { result: { name: 'test' }, valid: true, provider: :anthropic, model: 'claude-sonnet-4-6' }
    end

    before do
      allow(Legion::LLM::Call::StructuredOutput).to receive(:generate).and_return(structured_result)
    end

    it 'emits a deprecation warning' do
      expect(Legion::LLM::Deprecation).to receive(:warn_once).with(:structured_direct, replacement: 'Legion::LLM.structured').and_call_original
      Legion::LLM.structured_direct(messages: [{ role: :user, content: 'hi' }], schema: schema)
    end

    it 'emits a metering event' do
      Legion::LLM.structured_direct(messages: [{ role: :user, content: 'hi' }], schema: schema)
      expect(Legion::LLM::Metering).to have_received(:emit).with(
        hash_including(
          request_type: 'structured_output',
          event_type:   'llm_structured',
          tier:         'direct',
          status:       'success'
        )
      )
    end

    it 'metering event status reflects validation result' do
      allow(Legion::LLM::Call::StructuredOutput).to receive(:generate).and_return(
        { result: nil, valid: false, provider: :anthropic, model: 'claude-sonnet-4-6' }
      )
      Legion::LLM.structured_direct(messages: [{ role: :user, content: 'hi' }], schema: schema)
      expect(Legion::LLM::Metering).to have_received(:emit).with(
        hash_including(status: 'error')
      )
    end

    it 'returns the structured result unchanged' do
      result = Legion::LLM.structured_direct(messages: [{ role: :user, content: 'hi' }], schema: schema)
      expect(result).to eq(structured_result)
    end
  end
end
