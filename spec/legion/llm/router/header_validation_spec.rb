# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'

# G31 / opus M7 — P5 commit 2 implementation
RSpec.describe Legion::LLM::Inference::Executor::PayloadBuilder do
  describe '.parse_and_validate_header' do
    let(:taxonomy) { Legion::Extensions::Llm::Taxonomies::TIERS }

    it 'returns empty array for empty header' do
      result = described_class.parse_and_validate_header(headers: {}, name: 'x-legion-tiers', taxonomy: taxonomy)
      expect(result).to eq([])
    end

    it 'parses comma-separated valid tiers into symbol array' do
      headers = { 'x-legion-tiers' => 'direct,local' }
      result = described_class.parse_and_validate_header(headers: headers, name: 'x-legion-tiers', taxonomy: taxonomy)
      expect(result).to eq(%i[direct local])
    end

    it 'raises InvalidHeader for unknown tier value' do
      headers = { 'x-legion-tiers' => 'xyz' }
      caught = nil
      begin
        described_class.parse_and_validate_header(headers: headers, name: 'x-legion-tiers', taxonomy: taxonomy)
      rescue Legion::LLM::Errors::InvalidHeader => e
        caught = e
      end
      expect(caught).to be_a(Legion::LLM::Errors::InvalidHeader)
      expect(caught.header).to eq('x-legion-tiers')
      expect(caught.got).to include(:xyz)
      expect(caught.valid).to eq(taxonomy)
    end

    it 'raises InvalidHeader when mix of valid and invalid values' do
      headers = { 'x-legion-tiers' => 'direct,invalid_tier' }
      expect do
        described_class.parse_and_validate_header(headers: headers, name: 'x-legion-tiers', taxonomy: taxonomy)
      end.to raise_error(Legion::LLM::Errors::InvalidHeader)
    end
  end

  describe '.build' do
    let(:request) do
      Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hi' }],
        routing:  { model: 'gemma-12b' }
      )
    end

    it 'parses comma-separated x-legion-tiers header into payload[:tiers]' do
      payload = described_class.build(
        request: request, headers: { 'x-legion-tiers' => 'direct,local' }
      )
      expect(payload[:tiers]).to eq(%i[direct local])
    end

    it 'body model (from routing) becomes models: [body_model]' do
      req = Legion::LLM::Inference::Request.build(
        messages: [{ role: :user, content: 'hi' }],
        routing:  { model: 'gpt-5.4' }
      )
      payload = described_class.build(request: req, headers: {})
      expect(payload[:models]).to include('gpt-5.4')
    end

    it 'x-legion-max-attempts header overrides settings default' do
      payload = described_class.build(
        request: request, headers: { 'x-legion-max-attempts' => '5' }
      )
      expect(payload[:max_attempts]).to eq(5)
    end

    it 'body tier hints are ignored when allow_body_routing_hints is false (default)' do
      Legion::Settings[:llm][:routing][:allow_body_routing_hints] = false
      payload = described_class.build(request: request, headers: {})
      expect(payload[:tiers]).to eq([])
    end

    it 'tried_lanes starts empty' do
      payload = described_class.build(request: request, headers: {})
      expect(payload[:tried_lanes]).to eq([])
    end
  end
end

# G31 via real Sinatra app: POST with invalid x-legion-tiers header → 400
RSpec.describe 'Header validation via API (P5)' do
  include Rack::Test::Methods

  require 'sinatra/base'
  require 'sinatra/namespace'
  require 'legion/llm/api/namespaces/openai/chat/completions'

  let(:app) do
    Class.new(Sinatra::Base) do
      set :host_authorization, permitted: :any
      set :show_exceptions, false
      set :raise_errors, false
      register Sinatra::Namespace
      helpers Legion::LLM::API::Namespaces::Helpers
      register Legion::LLM::API::Namespaces::OpenAI::Chat::Completions
    end
  end

  before do
    stub_native_provider(content: 'response')
    write_test_lane(provider: :vllm, model: 'gemma-12b', tier: :direct)
    # Mark LLM as started so require_llm! doesn't halt the request
    Legion::LLM.instance_variable_set(:@started, true)
  end

  after do
    Legion::LLM.instance_variable_set(:@started, nil)
  end

  it 'returns 400 for unknown x-legion-tiers value via POST /v1/chat/completions' do
    post '/v1/chat/completions',
         Legion::JSON.dump({ model: 'gemma-12b', messages: [{ role: 'user', content: 'hi' }] }),
         'CONTENT_TYPE' => 'application/json', 'HTTP_X_LEGION_TIERS' => 'xyz'
    expect(last_response.status).to eq(400)
    body = Legion::JSON.load(last_response.body)
    expect(body[:error][:type]).to eq('invalid_header')
    expect(body[:error][:header]).to eq('x-legion-tiers')
  end
end
