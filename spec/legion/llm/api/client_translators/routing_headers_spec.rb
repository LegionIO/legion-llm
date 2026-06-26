# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/anthropic_messages'
require 'legion/llm/api/client_translators/openai_chat'
require 'legion/llm/api/client_translators/openai_responses'

RSpec.describe 'client translator Legion routing headers' do
  let(:env) do
    {
      'HTTP_X_LEGION_PROVIDER' => 'openai',
      'HTTP_X_LEGION_MODEL'    => 'gpt-5.4-mini',
      'HTTP_X_LEGION_INSTANCE' => 'env',
      'HTTP_X_LEGION_TIER'     => 'frontier'
    }
  end

  shared_examples 'a translator that prefers X-Legion-Model header over body model for routing' do |body|
    it 'routes only from X-Legion-* headers and preserves the client body model as metadata' do
      canonical_request = translator.parse_request(body, env)
      inference_request = translator.build_inference_request(
        canonical_request,
        request_id:    'req_test',
        server_caller: { source: 'spec' }
      )

      expect(canonical_request.routing).to eq(
        model: 'gpt-5.4-mini', provider: 'openai', instance: 'env'
      )
      expect(canonical_request.metadata[:client_model]).to eq('client-body-model')
      expect(inference_request.routing).to eq(
        model: 'gpt-5.4-mini', provider: 'openai', instance: 'env'
      )
      expect(inference_request.extra[:tier]).to eq(:frontier)
      expect(inference_request.extra[:routing_explicit]).to eq(
        model: true, provider: true, instance: true, tier: true
      )
    end

    it 'falls back to the body model for routing[:model] when X-Legion-Model is absent' do
      canonical_request = translator.parse_request(body, env.except('HTTP_X_LEGION_MODEL'))
      inference_request = translator.build_inference_request(
        canonical_request,
        request_id:    'req_test',
        server_caller: { source: 'spec' }
      )

      expect(canonical_request.routing).to eq(provider: 'openai', instance: 'env')
      expect(inference_request.routing).to eq(model: 'client-body-model', provider: 'openai', instance: 'env')
      expect(inference_request.extra[:auto_route]).to be_nil
      expect(inference_request.extra[:routing_explicit]).to eq(
        provider: true, instance: true, tier: true
      )
    end

    it 'leaves routing[:model] nil when the body model is the legionio sentinel and X-Legion-Model is absent' do
      canonical_request = translator.parse_request(body.merge(model: 'legionio'), env.except('HTTP_X_LEGION_MODEL'))
      inference_request = translator.build_inference_request(
        canonical_request,
        request_id:    'req_test',
        server_caller: { source: 'spec' }
      )

      expect(inference_request.routing[:model]).to be_nil
    end
  end

  describe Legion::LLM::API::ClientTranslators::OpenAIResponses do
    let(:translator) { described_class.new }

    include_examples 'a translator that prefers X-Legion-Model header over body model for routing',
                     { model: 'client-body-model', input: 'hello' }
  end

  describe Legion::LLM::API::ClientTranslators::OpenAIChat do
    let(:translator) { described_class.new }

    include_examples 'a translator that prefers X-Legion-Model header over body model for routing',
                     { model: 'client-body-model', messages: [{ role: 'user', content: 'hello' }] }
  end

  describe Legion::LLM::API::ClientTranslators::AnthropicMessages do
    let(:translator) { described_class.new }

    include_examples 'a translator that prefers X-Legion-Model header over body model for routing',
                     { model: 'client-body-model', max_tokens: 1024, messages: [{ role: 'user', content: 'hello' }] }
  end
end
