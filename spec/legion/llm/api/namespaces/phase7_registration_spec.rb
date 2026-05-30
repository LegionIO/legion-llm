# frozen_string_literal: true

require 'spec_helper'
require 'sinatra/base'

RSpec.describe 'Phase 7 namespace registration wiring' do
  before do
    require 'legion/llm/api/namespaces/registration'
  end

  let(:app) { Class.new(Sinatra::Base) }

  describe 'register_openai' do
    it 'does not raise when vector store files are loaded' do
      expect do
        require 'legion/llm/api/namespaces/openai/vector_stores'
        require 'legion/llm/api/namespaces/openai/vector_stores/files'
        require 'legion/llm/api/namespaces/openai/vector_stores/file_batches'
      end.not_to raise_error
    end

    it 'all three vector store modules extend Sinatra::Extension' do
      require 'legion/llm/api/namespaces/openai/vector_stores'
      require 'legion/llm/api/namespaces/openai/vector_stores/files'
      require 'legion/llm/api/namespaces/openai/vector_stores/file_batches'

      [
        Legion::LLM::API::Namespaces::OpenAI::VectorStores,
        Legion::LLM::API::Namespaces::OpenAI::VectorStores::Files,
        Legion::LLM::API::Namespaces::OpenAI::VectorStores::FileBatches
      ].each do |mod|
        expect(mod.singleton_class.ancestors).to include(Sinatra::Extension),
                                                 "Expected #{mod} to extend Sinatra::Extension"
      end
    end
  end
end
