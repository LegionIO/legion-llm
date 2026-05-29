# frozen_string_literal: true

require 'spec_helper'
require 'sinatra/base'

RSpec.describe 'Legion::LLM::API::Namespaces::Registration' do
  before do
    require 'legion/llm/api/namespaces/registration'
  end

  let(:app) { Class.new(Sinatra::Base) }

  describe '.registered' do
    it 'registers Sinatra::Namespace on the app' do
      Legion::LLM::API::Namespaces::Registration.registered(app)
      expect(app.extensions).to include(Sinatra::Namespace)
    end

    it 'includes Namespaces::Helpers on the app' do
      Legion::LLM::API::Namespaces::Registration.registered(app)
      test_app = app.new!
      expect(test_app).to respond_to(:parse_request_body)
      expect(test_app).to respond_to(:require_llm!)
      expect(test_app).to respond_to(:detect_client)
    end
  end
end
