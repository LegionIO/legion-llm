# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pipeline integration with Legion::LLM.chat' do
  before do
    Legion::Settings.merge_settings('llm', Legion::LLM::Settings.default)
    Legion::Settings[:llm][:pipeline_enabled] = true
    allow(Legion::LLM).to receive(:started?).and_return(true)
    stub_native_provider(content: 'pipeline response')
  end

  it 'returns a Inference::Response when pipeline is enabled' do
    result = Legion::LLM.chat(message: 'hello')
    expect(result).to be_a(Legion::LLM::Inference::Response)
    expect(result.message[:content]).to eq('pipeline response')
    expect(result.tracing).to be_a(Hash)
    expect(result.timeline).not_to be_empty
  end

  it 'treats string-keyed pipeline_enabled as enabled' do
    allow(Legion::LLM::Inference).to receive(:settings).and_return({
                                                                     'pipeline_enabled' => true,
                                                                     'default_model'    => SSOT_TEST_MODEL,
                                                                     'default_provider' => :vllm
                                                                   })

    expect(Legion::LLM::Inference.pipeline_enabled?).to be(true)
  end

  describe 'streaming via pipeline' do
    it 'uses call_stream when block is given and stream: true is set' do
      chunks = []
      result = Legion::LLM.chat(message: 'hello', stream: true) { |chunk| chunks << chunk }

      expect(chunks.map(&:content)).to eq(['pipeline response'])
      expect(result).to be_a(Legion::LLM::Inference::Response)
    end
  end

  it 'always returns an Inference::Response (pipeline is the only dispatch path in SSOT v3)' do
    # SSOT v3: the single-engine executor path always returns Inference::Response;
    # the legacy non-pipeline path no longer exists as a separate code path.
    result = Legion::LLM.chat(message: 'hello')
    expect(result).to be_a(Legion::LLM::Inference::Response)
  end
end
