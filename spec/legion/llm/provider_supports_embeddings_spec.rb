# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::LLM.provider_supports_embeddings?' do
  subject(:supports?) { Legion::LLM.provider_supports_embeddings?(provider) }

  context 'with nil' do
    let(:provider) { nil }
    it { is_expected.to be(false) }
  end

  context 'with :ollama' do
    let(:provider) { :ollama }
    it 'returns true (hardcoded; Ollama does not go through render_embedding_payload)' do
      expect(supports?).to be(true)
    end
  end

  context 'with :azure' do
    let(:provider) { :azure }
    it 'returns true (hardcoded; Azure does not go through render_embedding_payload)' do
      expect(supports?).to be(true)
    end
  end

  context 'with :anthropic' do
    let(:provider) { :anthropic }
    it 'returns false — hardcoded because the native Anthropic API has no embedding endpoint' do
      expect(supports?).to be(false)
    end
  end

  context 'with :bedrock' do
    let(:provider) { :bedrock }

    it 'returns false today — falls through to the NameError branch because the Bedrock provider class has not implemented render_embedding_payload' do
      # This test pins current behavior: Bedrock is no longer hardcoded-false,
      # but the instance_method probe raises NameError because the method is
      # not defined on the Bedrock class. When a sibling contribution adds
      # render_embedding_payload to lex-bedrock, this expectation should flip
      # to `be(true)` with no other change required here.
      expect(supports?).to be(false)
    end
  end

  context 'with an unknown provider' do
    let(:provider) { :does_not_exist }
    it 'returns false — RubyLLM::Provider.resolve returns nil' do
      expect(supports?).to be(false)
    end
  end
end
