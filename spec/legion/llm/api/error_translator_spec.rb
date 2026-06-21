# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'sinatra/base'
require 'legion/llm/api/error_translator'
require 'legion/llm/api/namespaces/helpers'

# G14 / D-G: NoLaneAvailable → 400, EscalationExhausted → 503 + Retry-After, InvalidHeader → 400
RSpec.describe Legion::LLM::API::ErrorTranslator do
  include Rack::Test::Methods

  # Minimal Sinatra app that uses the translator helpers
  let(:app) do
    Sinatra.new do
      set :host_authorization, permitted: :any
      helpers Legion::LLM::API::Namespaces::Helpers

      post '/test/no_lane' do
        error = Legion::LLM::Errors::NoLaneAvailable.new(filters: { tiers: [:local] })
        translate_no_lane_available(error, operation: 'test.no_lane')
      end

      post '/test/exhausted' do
        error = Legion::LLM::Errors::EscalationExhausted.new(
          attempts:    3,
          tried_lanes: %w[lane1 lane2],
          last_error:  RuntimeError.new('timeout')
        )
        translate_escalation_exhausted(error, operation: 'test.exhausted')
      end

      post '/test/invalid_header' do
        error = Legion::LLM::Errors::InvalidHeader.new(
          header: 'x-legion-tiers',
          got:    [:xyz],
          valid:  Legion::Extensions::Llm::Taxonomies::TIERS
        )
        translate_invalid_header(error, operation: 'test.invalid_header')
      end
    end
  end

  describe 'NoLaneAvailable → HTTP 400' do
    before { post '/test/no_lane' }

    it 'returns 400' do
      expect(last_response.status).to eq(400)
    end

    it 'returns JSON with type no_lane_available' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('no_lane_available')
    end

    it 'includes filters in the response body' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:filters]).to be_a(Hash)
    end

    it 'sets content-type to application/json' do
      expect(last_response.headers['Content-Type']).to include('application/json')
    end
  end

  describe 'EscalationExhausted → HTTP 503 + Retry-After' do
    before { post '/test/exhausted' }

    it 'returns 503' do
      expect(last_response.status).to eq(503)
    end

    it 'sets Retry-After header from settings' do
      retry_after = Legion::Settings[:llm][:api][:escalation_exhausted_retry_after]
      expect(last_response.headers['Retry-After']).to eq(retry_after.to_s)
    end

    it 'returns JSON with type escalation_exhausted' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('escalation_exhausted')
    end

    it 'includes attempts and tried_lanes_count' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:attempts]).to eq(3)
      expect(body[:error][:tried_lanes_count]).to eq(2)
    end
  end

  describe 'InvalidHeader → HTTP 400' do
    before { post '/test/invalid_header' }

    it 'returns 400' do
      expect(last_response.status).to eq(400)
    end

    it 'returns JSON with type invalid_header' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:type]).to eq('invalid_header')
    end

    it 'includes header name and valid values' do
      body = Legion::JSON.load(last_response.body)
      expect(body[:error][:header]).to eq('x-legion-tiers')
    end
  end
end
