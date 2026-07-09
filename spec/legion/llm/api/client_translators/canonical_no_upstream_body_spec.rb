# frozen_string_literal: true

require 'spec_helper'
require 'legion/llm/api/client_translators/openai_responses'

# Canonical-equivalence guard (mirrors legionio-e2e spec/canonical/*): a request
# must parse to the SAME Canonical::Request regardless of client format. The
# OpenAI Responses translator previously stashed the raw request body into
# Canonical::Request.metadata[:upstream_body], which the Anthropic Messages
# translator does not — so the two formats produced non-identical canonical
# requests and the e2e canonical-equivalence cells failed.
#
# upstream_body was dead weight in canonical metadata: it is written at parse
# time, stripped again in build_inference_request (`.except(:upstream_body)`),
# and the native call_responses path is fed the RAW body directly (see
# api/openai/responses.rb), never canonical metadata. Nothing reads it — so it
# must not live in the canonical request at all.
RSpec.describe 'OpenAI Responses translator canonical metadata' do
  let(:translator) { Legion::LLM::API::ClientTranslators::OpenAIResponses.new }
  let(:body) do
    {
      model:             'gemma-4-31b-it',
      max_output_tokens: 128,
      temperature:       0,
      input:             [{ role: 'user', content: 'Respond with exactly: pong' }]
    }
  end
  let(:env) { { 'HTTP_X_LEGION_PROVIDER' => 'vllm' } }

  it 'does not leak upstream_body into Canonical::Request.metadata' do
    canonical_request = translator.parse_request(body, env)
    expect(canonical_request.metadata).not_to have_key(:upstream_body)
  end

  it 'still produces the client_model + routing metadata it is supposed to' do
    canonical_request = translator.parse_request(body, env)
    expect(canonical_request.metadata[:client_model]).to eq('gemma-4-31b-it')
    expect(canonical_request.routing).to include(provider: 'vllm')
  end
end
